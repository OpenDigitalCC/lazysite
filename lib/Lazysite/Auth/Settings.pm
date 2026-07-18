package Lazysite::Auth::Settings;

# Per-user access-mechanism settings (lazysite/auth/user-settings.json) and the
# single-use consume lock, shared by the users tool and the dav endpoint
# (SM079). Context is $AUTH_DIR, set by each script after `use`.

use strict;
use warnings;
use Fcntl          qw(:flock);
use Lazysite::Util qw(log_event);
use Exporter 'import';

our @EXPORT_OK = qw(read_settings write_settings _consume_lock
    caps_for groups_grant_cap site_grants_manager
    group_scopes group_home_domain
    read_group_settings write_group_settings @CAP_KEYS);

our $AUTH_DIR;    # "$DOCROOT/lazysite/auth", set by the script

# SM095: the capability bools a group can carry. Channel caps (where you may
# operate) + action caps (what you may do). `ui` (Manager-UI login) converges from
# the per-account flag onto this list in the clean-cut phase.
our @CAP_KEYS = qw(
    ui webdav api mcp
    manage_content manage_nav manage_forms
    manage_themes manage_layouts manage_domains manage_config
    manage_users analytics audit notifications
    create_sub_users delegate_sub_user_creation);

sub _settings_file       { "$AUTH_DIR/user-settings.json" }
sub _group_settings_file { "$AUTH_DIR/groups-settings.json" }
sub _groups_file         { "$AUTH_DIR/groups" }

# Membership map { group => [members] } from the plain groups file.
sub _groups_membership {
    my %g;
    my $f = _groups_file();
    return %g unless -f $f;
    open my $fh, '<:utf8', $f or return %g;
    while (<$fh>) {
        chomp; s/^\s+|\s+$//g;
        next if /^#/ || !length;
        my ( $grp, $mem ) = split /:\s*/, $_, 2;
        next unless defined $mem;
        $g{$grp} = [ map { s/^\s+|\s+$//gr } split /,/, $mem ];
    }
    close $fh;
    return %g;
}

# Per-group capabilities + manager flag (read-only here; the users tool owns
# seeding + writes). { group => { manager=>1, <cap>=>1, ... } }.
# ADR 0001: JSON files are read as RAW OCTETS and decoded with decode_json
# (which expects UTF-8 bytes). Reading through a :utf8 layer first hands
# decode_json a character string, which dies on any non-ASCII content (e.g. a
# group description) and silently wiped the whole read to {}.
sub read_group_settings {
    require JSON::PP;
    my $f = _group_settings_file();
    return {} unless -f $f;
    open my $fh, '<:raw', $f or return {};
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $d = eval { JSON::PP::decode_json( $raw // '{}' ) };
    return ( ref $d eq 'HASH' ) ? $d : {};
}

# THE shared "does any of these groups grant capability $cap?" check - the
# request-context flavour of the resolver, used by the gates that already hold
# the requester's group list (login landing, per-file ACL operator bypass).
# Differs from caps_for, which resolves MEMBERSHIP from the groups file; here
# the caller supplies the groups and only the capability lookup is shared.
# ADR 0001 records this split and the one deliberate local copy (the
# processor's module-free render path).
sub groups_grant_cap {
    my ( $cap, @groups ) = @_;
    return 0 unless @groups;
    my $gs = read_group_settings();
    for my $g (@groups) {
        return 1 if ref $gs->{$g} eq 'HASH' && $gs->{$g}{$cap};
    }
    return 0;
}

# SM155: the content-root(s) a set of groups confine their members to. A group
# may carry a `dav_scope` (a content-root-relative subtree) - the domain binding
# that moved from the per-account setting to the group. Returns the distinct
# non-empty scopes across the given groups (0/1/many); empty means unconfined.
# A member of several scoped groups gets the UNION, consistent with how
# capabilities union across a user's groups (groups_grant_cap / _group_caps).
sub group_scopes {
    my (@groups) = @_;
    return () unless @groups;
    my $gs = read_group_settings();
    my ( %seen, @scopes );
    for my $g (@groups) {
        next unless ref $gs->{$g} eq 'HASH';
        my $s = $gs->{$g}{dav_scope};
        next unless defined $s && length $s;
        push @scopes, $s unless $seen{$s}++;
    }
    return @scopes;
}

# SM155: the home_domain (UI pointer) for single-domain rooting - defined only
# when EXACTLY ONE of the groups is scoped (a one-domain editor roots their file
# browser there; a multi-domain editor gets a switcher, a tracked follow-up).
# Returns '' otherwise.
sub group_home_domain {
    my (@groups) = @_;
    my $gs = read_group_settings();
    my @hd;
    for my $g (@groups) {
        next unless ref $gs->{$g} eq 'HASH';
        my $s = $gs->{$g}{dav_scope};
        next unless defined $s && length $s;    # only a scoped group carries one
        push @hd, ( $gs->{$g}{home_domain} // '' );
    }
    return ( @hd == 1 && length $hd[0] ) ? $hd[0] : '';
}

sub write_group_settings {
    require JSON::PP;
    my ($ref) = @_;
    my $file  = _group_settings_file();
    my $tmp   = "$file.tmp.$$";
    open my $fh, '>:utf8', $tmp or return 0;
    flock( $fh, LOCK_EX );
    print {$fh} JSON::PP->new->canonical->pretty->encode($ref);
    flock( $fh, LOCK_UN );
    close $fh;
    chmod 0660, $tmp;
    rename $tmp, $file or return 0;
    return 1;
}

# Union of capability bools across every group $user belongs to.
sub _group_caps {
    my ($user) = @_;
    my %groups = _groups_membership();
    my $gs     = read_group_settings();
    my %caps;
    for my $g ( keys %groups ) {
        next unless grep { $_ eq $user } @{ $groups{$g} || [] };
        my $cfg = $gs->{$g} or next;
        for my $k (@CAP_KEYS) { $caps{$k} = 1 if $cfg->{$k} }
    }
    return \%caps;
}

# SM138: is this site SECURED - does any group grant manager access (ui or
# manage_users, or carries the manager flag)? When nothing does, the site is in
# the unsecured/dev mode where any authenticated user is a manager (the fresh
# checkout / dev-server experience). This replaces "is manager_groups set in
# lazysite.conf" as the secured-site signal - the conf key is retired.
sub site_grants_manager {
    my $gs = read_group_settings();
    for my $g ( keys %{$gs} ) {
        my $cfg = $gs->{$g};
        next unless ref $cfg eq 'HASH';
        return 1 if $cfg->{ui} || $cfg->{manage_users} || $cfg->{manager};
    }
    return 0;
}

# THE central capability resolver - every surface (manager UI, control API, MCP,
# and the WebDAV endpoint) consults this and only this. Returns { cap => 0|1 }.
# SM095 clean cut: capabilities come from the account's GROUPS only - the union
# across them, each capability explicit (no per-user grants, no inheritance). The
# interactive-login gate still reads the per-account `ui` flag until phase (c2)
# wires it to the `ui` capability here.
sub caps_for {
    my ($user) = @_;
    my $gc     = _group_caps($user);
    my %c      = map { $_ => ( $gc->{$_} ? 1 : 0 ) } @CAP_KEYS;
    return \%c;
}

# JSON object keyed by username. Unparseable content yields defaults (empty)
# plus a WARN, so a corrupt file cannot wedge management.
sub read_settings {
    require JSON::PP;
    my $file = _settings_file();
    return {} unless -f $file;
    # Raw octets for decode_json - same convention as read_group_settings
    # (ADR 0001); a non-ASCII email/comment used to kill the whole read.
    open my $fh, '<:raw', $file or do {
        log_event( 'WARN', 'settings', 'cannot read user-settings.json', error => "$!" );
        return {};
    };
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $data = eval { JSON::PP::decode_json( $raw // '{}' ) };
    if ( !$data || ref $data ne 'HASH' ) {
        log_event( 'WARN', 'settings', 'user-settings.json unparseable; using defaults' );
        return {};
    }
    return $data;
}

# Single writer; write-temp-then-rename. Group-writable (0660) so the CLI and a
# www-data CGI both manage it.
sub write_settings {
    my ($data) = @_;
    require JSON::PP;
    my $file = _settings_file();
    my $json = JSON::PP->new->canonical->pretty->encode($data);
    my $tmp  = "$file.tmp.$$";
    open my $fh, '>:utf8', $tmp or die "Cannot write $file: $!\n";
    flock( $fh, LOCK_EX );
    print {$fh} $json;
    flock( $fh, LOCK_UN );
    close $fh;
    chmod 0660, $tmp;
    rename $tmp, $file
        or die "Cannot rename settings file into place: $!\n";
}

# Exclusive lock held until the returned handle goes out of scope (the caller's
# function returns) or the process exits - serialises single-use redemption so
# the same secret cannot be consumed twice. Fail-open (undef) if unlockable.
sub _consume_lock {
    my $path = "$AUTH_DIR/.consume.lock";
    open my $lk, '>', $path or return undef;
    flock( $lk, LOCK_EX ) or do { close $lk; return undef };
    return $lk;
}

1;
