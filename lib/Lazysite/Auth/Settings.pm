package Lazysite::Auth::Settings;

# Per-user access-mechanism settings (lazysite/auth/user-settings.json) and the
# single-use consume lock, shared by the users tool and the dav endpoint
# (SM079). Context is $AUTH_DIR, set by each script after `use`.

use strict;
use warnings;
use Fcntl qw(:flock);
use Lazysite::Util qw(log_event);
use Exporter 'import';

our @EXPORT_OK = qw(read_settings write_settings _consume_lock
    caps_for read_group_settings write_group_settings @CAP_KEYS);

our $AUTH_DIR;    # "$DOCROOT/lazysite/auth", set by the script

# SM095: the capability bools a group (or, transitionally, an account) can carry.
# Action capabilities only; the seeded set is extended with channel caps (ui,
# webdav, api, mcp) and manage_users by the refactor.
our @CAP_KEYS = qw(webdav manage_content manage_nav manage_forms
    manage_themes manage_layouts manage_config analytics
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
sub read_group_settings {
    require JSON::PP;
    my $f = _group_settings_file();
    return {} unless -f $f;
    open my $fh, '<:utf8', $f or return {};
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $d = eval { JSON::PP::decode_json( $raw // '{}' ) };
    return ( ref $d eq 'HASH' ) ? $d : {};
}

sub write_group_settings {
    require JSON::PP;
    my ($ref) = @_;
    my $file = _group_settings_file();
    my $tmp  = "$file.tmp.$$";
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

# THE central capability resolver - every surface (manager UI, control API, MCP,
# and the WebDAV endpoint) consults this and only this. Returns { cap => 0|1 }.
# Transitionally it unions group grants with any legacy per-user grant (and keeps
# the manage_content->webdav / nav,forms->content back-compat defaults) so the
# move to one resolver changes WHERE caps come from, not WHAT they are.
sub caps_for {
    my ($user) = @_;
    my $s  = read_settings()->{$user} || {};
    my $gc = _group_caps($user);
    my %c;
    for my $k (qw(webdav manage_themes manage_layouts manage_config analytics
        create_sub_users delegate_sub_user_creation)) {
        $c{$k} = ( $s->{$k} || $gc->{$k} ) ? 1 : 0;
    }
    my $content = ( defined $s->{manage_content} ? $s->{manage_content} : $s->{webdav} )
        || $gc->{manage_content};
    $c{manage_content} = $content ? 1 : 0;
    $c{manage_nav} = ( ( defined $s->{manage_nav} ? $s->{manage_nav} : $content )
        || $gc->{manage_nav} ) ? 1 : 0;
    $c{manage_forms} = ( ( defined $s->{manage_forms} ? $s->{manage_forms} : $content )
        || $gc->{manage_forms} ) ? 1 : 0;
    return \%c;
}

# JSON object keyed by username. Unparseable content yields defaults (empty)
# plus a WARN, so a corrupt file cannot wedge management.
sub read_settings {
    require JSON::PP;
    my $file = _settings_file();
    return {} unless -f $file;
    open my $fh, '<:utf8', $file or do {
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
