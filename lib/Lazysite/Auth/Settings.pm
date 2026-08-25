package Lazysite::Auth::Settings;

# Per-user access-mechanism settings (lazysite/auth/user-settings.json) and the
# single-use consume lock, shared by the users tool and the dav endpoint
# (SM079). Context is $AUTH_DIR, set by each script after `use`.

use strict;
use warnings;
use Fcntl          qw(:flock);
use JSON::PP       ();
use Lazysite::Util qw(log_event secure_write_perms);
use Exporter 'import';

our @EXPORT_OK = qw(read_settings write_settings _consume_lock
    caps_for groups_grant_cap site_grants_manager
    effective_groups touch_credential
    resolve_user_scopes resolve_home_domain resolve_token_ttl
    read_group_settings write_group_settings group_is_assignable @CAP_KEYS);

our $AUTH_DIR;    # "$DOCROOT/lazysite/auth", set by the script

# SM212: machine-token (lzs_) lifetime policy. The default is short; an operator
# may set a per-account `token_ttl` up to a hard ceiling, and an account that
# carries one also gets sliding renewal (see touch_credential). One home for the
# numbers, shared by the users tool (issue/rotate/validate) and touch_credential.
our $ACCESS_TOKEN_TTL_DEFAULT = 86_400;         # 24h - default when no token_ttl set
our $TOKEN_TTL_MIN            = 3_600;          # 1h floor for an operator-set TTL
our $TOKEN_TTL_MAX            = 30 * 86_400;    # 30d hard ceiling (OAuth refresh horizon)

# The effective TTL (seconds) for an account's settings hashref: the operator-set
# token_ttl clamped to the ceiling, else the default. Never returns > the ceiling,
# so even a hand-edited/legacy record cannot mint a longer-lived token.
sub resolve_token_ttl {
    my ($settings) = @_;
    my $ttl = ref $settings eq 'HASH' ? $settings->{token_ttl} : undef;
    return $ACCESS_TOKEN_TTL_DEFAULT
        unless defined $ttl && $ttl =~ /^\d+$/ && $ttl > 0;
    $ttl = $TOKEN_TTL_MAX if $ttl > $TOKEN_TTL_MAX;
    return $ttl;
}

# SM095: the capability bools a group can carry. Channel caps (where you may
# operate) + action caps (what you may do). `ui` (Manager-UI login) converges from
# the per-account flag onto this list in the clean-cut phase.
our @CAP_KEYS = qw(
    ui webdav api mcp
    manage_content manage_nav manage_forms
    manage_themes manage_layouts manage_domains manage_config
    manage_users analytics audit notifications feedback read_submissions
    create_sub_users delegate_sub_user_creation
    manage_data manage_briefs
    housekeeping purge);

# SM591: the LATERAL grants. Deletion and tidying are the same job wherever they
# happen, and they are the operations an operator most often reserves to one
# person - so they answer a grant of their own instead of each module's, and
# "may use this module" stops meaning "may destroy inside it".
#
# TWO tiers, and which one an action joins is SM587's copy test - does the
# engine retain a copy? - never a judgement about how alarming the verb sounds:
#
#   housekeeping  a copy survives (data-table-drop mints a safety export)
#   purge         no copy survives (brief-delete, data-safety-export-delete,
#                 backup-delete, artefact backups)
#
# They are INDEPENDENT. `purge` does not imply `housekeeping`; an operator who
# wants a housekeeper grants both. A tier that silently contained the other
# would be a rule nobody can read off the table.
#
# Self-healing operations (cache-invalidate, the registry sweeps) join neither:
# they rebuild on the next request, so there is nothing to reserve.

# SM447 / ADR 0009: `manage_data` is DECLARED BY THE DATA PLUGIN and mirrored
# here, which is a different thing from being a core capability. SM576 part 1
# adds `manage_briefs` on exactly that pattern - declared by plugins/briefs.pl,
# mirrored here, discovered by t/lint/76 - so briefs stop riding manage_content
# and the right to write another principal's authoring record is grantable on
# its own (SM575 measured what happens when it is not).
#
# The list must be static. caps_for() is consulted on every request through
# every channel, and discovering capabilities by running each plugin's
# `--describe` would put ten subprocesses on that path. So the runtime keeps
# this literal and t/lint/76 DISCOVERS the plugin declarations and fails if the
# two disagree - which is ADR 0009's "the contract does not exempt a plugin
# from the lints, it makes the lints discover the plugin's entries", applied
# where it can be applied without a cost the request path cannot pay.
#
# The plugin remains the OWNER: it is the one place that says what it owns, and
# a capability appearing here with no plugin claiming it, or claimed by two
# plugins, is what the lint refuses. This entry is a mirror, not a second
# owner.

sub _settings_file       { "$AUTH_DIR/user-settings.json" }
sub _group_settings_file { "$AUTH_DIR/groups-settings.json" }
sub _groups_file         { "$AUTH_DIR/groups" }

# SM121 (compound groups): a group may list ANOTHER GROUP among its members, so
# that group's members inherit the parent's capabilities and scope. Given a set
# of group names, return them PLUS every group that (transitively) lists one of
# them as a member. A member is treated as a sub-group only when it is a known
# group name; a cycle terminates via the seen-set. This is the one place the
# group graph is walked; the resolvers below all route through it.
sub _group_closure {
    my (@seed)     = @_;
    my %membership = _groups_membership();
    my $gs         = read_group_settings();
    my %is_group   = map { $_ => 1 } ( keys %membership, keys %{$gs} );
    my %parent;    # sub-group => [ groups that list it as a member ]
    for my $g ( keys %membership ) {
        for my $m ( @{ $membership{$g} } ) {
            push @{ $parent{$m} }, $g if $is_group{$m} && $m ne $g;
        }
    }
    my %eff   = map { $_ => 1 } grep { defined && length } @seed;
    my @stack = keys %eff;
    while ( defined( my $g = pop @stack ) ) {
        for my $p ( @{ $parent{$g} || [] } ) {
            next if $eff{$p};
            $eff{$p} = 1;
            push @stack, $p;
        }
    }
    return keys %eff;
}

# The compound-expanded groups a USER belongs to: the groups that list them
# directly, closed upward over sub-group membership.
sub _effective_groups {
    my ($user)     = @_;
    my %membership = _groups_membership();
    my @direct = grep { grep { $_ eq $user } @{ $membership{$_} || [] } } keys %membership;
    return _group_closure(@direct);
}

# Public: the compound-expanded groups a user belongs to (SM121/SM165). The
# domain-access resolver needs the same expanded set the capability resolver uses.
sub effective_groups { return _effective_groups(@_) }

# Public: close a set of GROUP names upward over sub-group membership. Callers
# that already hold group names (the ACL read decision, SM268 01-L1) need the
# same expansion as callers that start from a username.
sub group_closure { return _group_closure(@_) }

# SM165: THE shared scope resolver for every enforcement channel (manager cookie,
# control-API token, WebDAV - all route here, directly or via effective_settings).
# A user's effective content-root scopes come from DOMAIN access (each domain's
# allowed_groups + locked_users), then are capped by the sub-user ceiling
# (intersected with every ancestor's own scope up the created_by chain, at
# resolve time so config drift cannot lift the ceiling). Cycle-guarded. Returns
# the scope list; empty = unconfined, a DENY_ALL_SCOPE element = confined to
# nothing.
#
# SM194 (scope emancipation): an operator may set `scope_independent: 1` on an
# account to genuinely unconfine it from its CREATOR. Management promotion
# (managed_by = none) alone does NOT do this - the walk below follows created_by,
# not managed_by, so a promoted user stays scope-capped by whoever created them
# (the deliberate confinement spine). When the flag is set, the created_by walk
# STOPS at that user: their own domain scope stands, uncapped by ancestors. The
# flag is honoured on the STARTING user only - it is that account's emancipation,
# a distinct operator-audited decision; created_by itself is never rewritten
# (immutable provenance; audit integrity depends on it).
sub resolve_user_scopes {
    my ( $docroot, $user ) = @_;
    require Lazysite::Auth::DomainAccess;
    my $domains = Lazysite::Auth::DomainAccess::read_domains("$docroot/lazysite/lazysite.conf");
    my @scopes = Lazysite::Auth::DomainAccess::effective_scopes(
        $domains, $user, [ _effective_groups($user) ] );
    my $all  = read_settings();
    my %seen = ( defined $user ? ( $user => 1 ) : () );
    my $self = $all->{ $user // '' } || {};
    my $anc  = $self->{scope_independent} ? undef : $self->{created_by};
    while ( defined $anc && length $anc && !$seen{$anc}++ ) {
        my @as = Lazysite::Auth::DomainAccess::effective_scopes(
            $domains, $anc, [ _effective_groups($anc) ] );
        @scopes = Lazysite::Auth::DomainAccess::intersect_scopes( \@scopes, \@as );
        $anc    = ( $all->{$anc} || {} )->{created_by};
    }
    return @scopes;
}

# SM165: the single domain a user's file browser roots at (host), or '' for
# none/several. '' when the ceiling denies everything.
sub resolve_home_domain {
    my ( $docroot, $user ) = @_;
    require Lazysite::Auth::DomainAccess;
    my $domains = Lazysite::Auth::DomainAccess::read_domains("$docroot/lazysite/lazysite.conf");
    my $hd = Lazysite::Auth::DomainAccess::effective_home_domain(
        $domains, $user, [ _effective_groups($user) ] );
    my $DA = Lazysite::Auth::DomainAccess::DENY_ALL_SCOPE();
    return ( grep { $_ eq $DA } resolve_user_scopes( $docroot, $user ) ) ? '' : $hd;
}

# Membership map { group => [members] } from the plain groups file.
sub _groups_membership {
    local $_;    # SM420: while(<>) assigns the GLOBAL $_
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
    for my $g ( _group_closure(@groups) ) {    # SM121: compound-expanded
        return 1 if ref $gs->{$g} eq 'HASH' && $gs->{$g}{$cap};
    }
    return 0;
}

# SM279: group_scopes / group_home_domain were REMOVED here.
#
# SM155 put the domain binding on the group; SM165 moved confinement to the
# domain-owned model in 0.7.26 (docs/SECURITY.md records that as an accepted
# decision) and resolve_user_scopes has read Lazysite::Auth::DomainAccess ever
# since. These two resolvers were left behind, exported, and called by nothing -
# so the group `dav_scope` they read was accepted, stored, and enforced nowhere.
#
# Deleted rather than deprecated: a resolver nothing calls is not a compatibility
# surface, it is a second answer to a question that must have exactly one. The
# CLI verb that wrote the field is refused in tools/lazysite-users.pl, and
# lazysite-check reports any stale value still in the store.
#
# Confinement, in one place: resolve_user_scopes -> DomainAccess::effective_scopes
# (the content roots of the domains a user's groups may manage), intersected up
# the created_by chain so a sub-user can never out-reach its creator.

# SM576 part 3: is this group one to give a PERSON, or a backend group that
# exists only to aggregate other groups and capabilities?
#
# Nesting already works and is already the enforcement path (_group_closure
# above); the distinction this answers is the one thing that was missing, and
# it is a distinction about INTENT that no amount of reading the graph can
# recover - "content-write" and "Site editor" have the same shape.
#
# TWO FALLBACKS, both deliberate:
#
#   NO RECORD AT ALL. A group that exists only in the membership file holds no
#   capabilities, so it aggregates nothing and refusing a member would cost an
#   operator something and protect nobody.
#
#   THE FLAG HAS NEVER BEEN SEEN. Until any group in the store carries it, the
#   store predates the flag and every group in it was assignable - because
#   that was the only kind there was. The users tool backfills the store the
#   first time it lists groups, so this fallback is what covers the window
#   before that write, never a permanent second meaning.
sub group_is_assignable {
    my ( $group, $gs ) = @_;
    $gs ||= read_group_settings();
    my $cfg = $gs->{$group};
    return 1 unless ref $cfg eq 'HASH' && %{$cfg};
    return 1
        unless grep { ref $gs->{$_} eq 'HASH' && exists $gs->{$_}{assignable} }
        keys %{$gs};
    return $cfg->{assignable} ? 1 : 0;
}

# DA-23: write-temp, lock, rename - once for this file's two JSON stores.
# Both take secure_write_perms at 0660 (SM289: root must not own an auth
# store; SM428: group-writable, because the CLI and the www-data CGI both
# write here), so the shared helper is not picking between two permission
# rules - there is one. Acl's and OAuth's writers stay where they are: they
# use a different output layer, no lock, and OAuth a bare chmod, and folding
# those needs the SM289 question ruled first.
#
# Returns ( 1, '' ) or ( 0, 'open' | 'rename' ). The STAGE is returned rather
# than one boolean because write_settings dies with a different sentence for
# each, and an operator reads that sentence.
sub _write_json_atomic {
    my ( $file, $ref ) = @_;
    my $json = JSON::PP->new->canonical->pretty->encode($ref);
    my $tmp  = "$file.tmp.$$";
    open my $fh, '>:utf8', $tmp or return ( 0, 'open' );
    flock( $fh, LOCK_EX );
    print {$fh} $json;
    flock( $fh, LOCK_UN );
    close $fh;
    secure_write_perms( $tmp, 0660 );
    return rename( $tmp, $file ) ? ( 1, '' ) : ( 0, 'rename' );
}

sub write_group_settings {
    my ($ref) = @_;
    my ($ok)  = _write_json_atomic( _group_settings_file(), $ref );
    return $ok;
}

# Union of capability bools across every group $user belongs to.
sub _group_caps {
    my ($user) = @_;
    my $gs = read_group_settings();
    my %caps;
    for my $g ( _effective_groups($user) ) {    # SM121: compound-expanded groups
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
# SM334: memoised per process, keyed on the file's identity.
#
# This is read on EVERY token verification. touch_credential calls it to decide
# whether the "last used" stamp is stale - a decision that needs the stored
# timestamps - and its comment calls that "one cheap read". It is not cheap: it
# opens, slurps and decode_json's the whole user-settings file, and under the
# FastCGI pool one worker does that for every authenticated request it serves.
#
# Measured across the release line, verify_token_ms drifted 32.7 -> 41.7 ms since
# the 2026-07-02 baseline, and a bisect puts the largest single step (+2.9 ms,
# +8%) between v0.7.24 and v0.7.26 - the window that added this read (SM163).
# The 2x perf tolerance passed it, and every step since.
#
# KEYED ON (mtime, size), NOT TIME. This cache decides who may do what, so a
# stale entry is an access-control answer from the past: a capability revoked
# through the CLI would keep working until the entry expired. Keying on the
# file's identity means a write invalidates it immediately and correctness does
# not depend on a window being short enough.
#
# Same shape as the processor's _peek_md, and per-process rather than global for
# the same reason: under CGI one process is one request and this changes nothing,
# while under FastCGI it removes nearly every read.
{
    my %_settings_cache;

    sub _settings_cache_clear { %_settings_cache = (); return }

    sub read_settings {
        my $file = _settings_file();
        return {} unless -f $file;

        my @st  = stat $file;
        my $key = @st ? "$file:$st[9]:$st[7]" : '';
        return $_settings_cache{$key} if length $key && exists $_settings_cache{$key};
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

        # One entry per (file, mtime, size). The map is bounded by how many distinct
        # versions of one file a single process sees, which is one in practice and a
        # handful in a long-lived worker that outlives several writes.
        # DO NOT CACHE A FILE THAT WAS JUST WRITTEN. mtime is one-second granular, so
        # a write landing in the same second as this read - with the same size, which
        # a capability flip like "ui":1 -> "ui":0 produces exactly - would carry an
        # identical key and serve the superseded settings. This is an access-control
        # answer, so that window is not acceptable even though it is narrow. A file
        # younger than a second is read fresh every time until it settles.
        if ( length $key && @st && $st[9] < time() - 1 ) {
            %_settings_cache = () if keys %_settings_cache > 8;
            $_settings_cache{$key} = $data;
        }
        return $data;
    }
}

# Single writer; write-temp-then-rename. Group-writable (0660) so the CLI and a
# www-data CGI both manage it.
sub write_settings {
    my ($data) = @_;
    my $file = _settings_file();
    my ( $ok, $stage ) = _write_json_atomic( $file, $data );
    unless ($ok) {
        die "Cannot write $file: $!\n" if $stage eq 'open';
        die "Cannot rename settings file into place: $!\n";
    }

    # SM334: this process must not answer from a cache it has just superseded.
    # The (mtime,size) key handles another process's write; this handles our own,
    # which is the case where a capability change and the next authorisation are
    # milliseconds apart.
    _settings_cache_clear();
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

# SM163: record that an account's machine credential was USED - so the Sessions &
# Keys view shows an active key as in-use with a recent time, not "not used yet".
# Called from EVERY credential path (control-API token verify, WebDAV Basic auth,
# MCP verify), not just the connector, since a key is typically used over api/dav
# and never touched the connector. THROTTLED: writes at most once per window
# (default 300s), so a key hammering DAV does not rewrite user-settings.json per
# request - one cheap read, a write only when the stamp is stale. Best-effort:
# any failure is swallowed (never block a request to record telemetry).
our $TOUCH_WINDOW = 300;

sub touch_credential {
    my ( $user, $now ) = @_;
    return 0 unless defined $user && length $user;
    $now ||= time();
    my $ok = eval {
        my $all  = read_settings();
        my $u    = $all->{$user}        || {};
        my $last = $u->{cred_used_at}   || 0;
        my $iss  = $u->{cred_issued_at} || 0;

        # Write when never used since the current issuance, or the last stamp is
        # older than the throttle window (keeps "last used" reasonably current).
        return 0 if $last >= $iss && ( $now - $last ) < $TOUCH_WINDOW;

        $all->{$user}{cred_used_at} = $now;

        # SM212: sliding renewal. An account the operator gave a token_ttl is a
        # managed long-lived credential - renew its expiry on use, so an in-use
        # token never lapses and only genuine inactivity (a full token_ttl) does.
        # Piggybacks this already-throttled write (at most one slide per window).
        # Guards: only a live token (expiry present and not yet past); never a
        # default-TTL token (no token_ttl -> unchanged 24h-from-issuance posture);
        # never shorten; never resurrect an expired one.
        if ( $u->{token_ttl}
            && $u->{token_expires_at}
            && $u->{token_expires_at} > $now )
        {
            my $slid = $now + resolve_token_ttl($u);
            $all->{$user}{token_expires_at} = $slid
                if $slid > $u->{token_expires_at};
        }

        write_settings($all);
        1;
    };
    return $ok ? 1 : 0;
}

1;
