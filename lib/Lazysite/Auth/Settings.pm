package Lazysite::Auth::Settings;

# Per-user access-mechanism settings (lazysite/auth/user-settings.json) and the
# single-use consume lock, shared by the users tool and the dav endpoint
# (SM079). Context is $AUTH_DIR, set by each script after `use`.

use strict;
use warnings;
use Fcntl           qw(:flock);
use JSON::PP        ();
use Lazysite::Util  qw(log_event secure_write_perms cannot_read);
use Lazysite::Paths ();
use Exporter 'import';

our @EXPORT_OK = qw(read_settings write_settings _consume_lock
    caps_for display_name_for display_names_for display_names_block settings_readable
    groups_grant_cap site_grants_manager
    effective_groups touch_credential
    resolve_user_scopes resolve_home_domain resolve_token_ttl
    read_group_settings write_group_settings group_is_assignable @CAP_KEYS);

our $AUTH_DIR; # auth/ in the engine tree (Lazysite::Paths::lazysite_dir), set by the script

# SM212: machine-token (lzs_) lifetime policy. The default is short; an operator
# may set a per-account `token_ttl` up to a hard ceiling, and an account that
# carries one also gets sliding renewal (see touch_credential). One home for the
# numbers, shared by the users tool (issue/rotate/validate) and touch_credential.
our $ACCESS_TOKEN_TTL_DEFAULT = 86_400;         # 24h - default when no token_ttl set
our $TOKEN_TTL_MIN            = 3_600;          # 1h floor for an operator-set TTL
our $TOKEN_TTL_MAX            = 30 * 86_400;    # 30d hard ceiling (OAuth refresh horizon)

# The effective TTL (seconds) for an account's settings hashref: the sysop-set
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
    manage_themes manage_layouts manage_domains manage_config manage_services
    manage_users analytics audit notifications feedback read_submissions
    create_sub_users delegate_sub_user_creation
    manage_data write_data manage_briefs
    run_jobs manage_connectors
    housekeeping purge audit_switch);

# SM591: the LATERAL grants. Deletion and tidying are the same job wherever they
# happen, and they are the operations a sysop most often reserves to one
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
# They are INDEPENDENT. `purge` does not imply `housekeeping`; a sysop who
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
sub groups_file          { "$AUTH_DIR/groups" }
sub users_file           { "$AUTH_DIR/users" }

# SM641: ONE ANSWER TO "is this name an account".
#
# Two surfaces need it and they must not disagree. lazysite-auth.pl asks before
# writing a name into the audit trail's actor column; the manager API asks
# before offering that actor as a link to the Users page. If those two answers
# could differ, the trail would either link something that is not there or
# refuse to link something that is - and the second is worse, because it makes
# a real account look invented.
#
# Names only. The credential half is deliberately not returned: nothing that
# asks this question needs it, and a hash that never leaves this sub cannot be
# logged by accident.
sub account_names {
    my $path = users_file();
    # SM778: same guard, same hole in lint 121, and this one is worse - the
    # audit page asks account_names WHICH ACTORS ARE REAL ACCOUNTS, so an
    # unsearchable auth directory silently unlinked every actor in the trail.
    # Configuration is this module's question; absence is the open's.
    return {} unless defined $AUTH_DIR;
    open my $fh, '<:utf8', $path or return ( cannot_read( 'users', $path ) // {} );
    my %names;
    while ( my $line = <$fh> ) {
        chomp $line;
        $line =~ s/^\s+|\s+$//g;
        next if !length $line || $line =~ /^#/;
        my ($u) = split /:/, $line, 2;
        $names{$u} = 1 if defined $u && length $u;
    }
    close $fh;
    return \%names;
}

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
    return _group_closure_in( \%membership, $gs, @seed );
}

# The walk itself, against stores the CALLER supplies.
#
# Split out for SM879: the Groups page needs the ancestry of EVERY group at
# once, and _groups_membership is not memoised - it opens and re-parses the
# groups file on each call, so closing each group separately would read that
# file once per group on a page that has already read it. Splitting keeps ONE
# implementation of the walk rather than giving the display its own copy, which
# is how the two would come to disagree about who inherits what.
sub _group_closure_in {
    my ( $membership, $gs, @seed ) = @_;
    my %is_group = map { $_ => 1 } ( keys %{$membership}, keys %{ $gs || {} } );
    my %parent;    # sub-group => [ groups that list it as a member ]
    for my $g ( keys %{$membership} ) {
        for my $m ( @{ $membership->{$g} } ) {
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

# Public: close a set of group names using stores the caller already holds.
sub group_closure_in { return _group_closure_in(@_) }

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
# SM194 (scope emancipation): a sysop may set `scope_independent: 1` on an
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
    my $domains = Lazysite::Auth::DomainAccess::read_domains( Lazysite::Paths::lazysite_dir($docroot) . "/lazysite.conf" );
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
    my $domains = Lazysite::Auth::DomainAccess::read_domains( Lazysite::Paths::lazysite_dir($docroot) . "/lazysite.conf" );
    my $hd = Lazysite::Auth::DomainAccess::effective_home_domain(
        $domains, $user, [ _effective_groups($user) ] );
    my $DA = Lazysite::Auth::DomainAccess::DENY_ALL_SCOPE();
    return ( grep { $_ eq $DA } resolve_user_scopes( $docroot, $user ) ) ? '' : $hd;
}

# Membership map { group => [members] } from the plain groups file.
sub _groups_membership {
    local $_;    # SM420: while(<>) assigns the GLOBAL $_
    my %g;
    my $f = groups_file();
    # SM770: the open decides.
    open my $fh, '<:utf8', $f or return ( cannot_read( 'groups', $f ) // %g );
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
    # SM770: the open decides.
    open my $fh, '<:raw', $f or return ( cannot_read( 'groups-settings.json', $f ) // {} );
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
# each, and a sysop reads that sentence.
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
# SM743: the display name for an account, or '' when it has none.
#
# The field was stored, editable and read by NOTHING. `display_name` had one
# reader in the whole tree - the users tool, which is also its only writer - so
# an operator could set it, watch it save, and never see it again. Meanwhile
# the admin bar is written to prefer a display name over the login
# (lazysite-processor.pl, `$vars->{auth_name} || $vars->{auth_user}`) and
# `auth_name` had one producer: the X-Remote-Name header, set by an upstream
# proxy. On a site using lazysite's own auth there was no path between them.
#
# RAW, DELIBERATELY. Escaping happens at the sinks - SM709 escapes where the
# TT stash is built and again at the admin bar, which reads %AUTH_CONTEXT
# directly - so escaping here would double-escape and render `O'Brien` as
# `O&#39;Brien` on the page. The value that travels is the value the operator
# typed.
#
# read_settings is memoised on the settings file's identity, so this is a hash
# lookup on any request that has already resolved capabilities, which every
# authenticated request has.
sub display_name_for {
    my ($user) = @_;
    return '' unless defined $user && length $user;
    my $s = read_settings();
    return '' unless ref $s eq 'HASH' && ref $s->{$user} eq 'HASH';
    my $n = $s->{$user}{display_name};
    return defined $n ? $n : '';
}

# SM778: THE SAME QUESTION FOR A LIST, WHICH IS WHAT EVERY LISTING ASKS.
#
# Reported from familyhq.explore: a site rendering bylines had no route from a
# login to a display name except for its own viewer, so it mirrored the names
# into its own table and the mirror drifted until every byline read as a bare
# login. The engine holds the names and hands back logins without them.
#
# Given the logins a response is about, this returns the names it HAS - and
# only those. A login with no entry is simply absent from the map, which is
# the honest shape: the caller already has the login and renders it, and a
# map that carried `login => login` would make "no name set" indistinguishable
# from "the name happens to equal the login".
#
# `readable` is the fourth state (SM784), passed through from the read: 0 says
# an absent entry means UNKNOWN, not unset, and a surface that cares can say
# so instead of quietly showing a login.
#
# THIS DISCLOSES NOTHING. It answers only for logins the caller supplied, and
# every surface that calls it is already handing that login back in the same
# response. It is not, and must not become, a way to enumerate accounts.
sub display_names_for {
    my (@logins) = @_;
    my $s = read_settings();
    my %names;
    for my $l (@logins) {
        next unless defined $l && length $l;
        next if exists $names{$l};
        next unless ref $s eq 'HASH' && ref $s->{$l} eq 'HASH';
        my $n = $s->{$l}{display_name};
        next unless defined $n && length $n;
        $names{$l} = $n;
    }
    return { names => \%names, readable => settings_readable() };
}

# SM778: THE ONE SHAPE EVERY RESPONSE USES, so the two keys are spelled once.
#
# A `display_names` map beside whatever carries the logins, holding an entry
# ONLY for a login that has a name: a caller that finds no entry renders the
# login exactly as it does today, which is why this can be added to a response
# without changing what any existing consumer sees. A map that carried
# `login => login` would instead make "no name set" indistinguishable from "the
# name happens to equal the login".
#
# `display_names_readable` is the fourth state (SM784) travelling with the
# answer: a missing entry means "no name set" when it is true and "the engine
# could not tell" when it is false. A surface that draws a person's name needs
# the difference - the whole point of the rule is that an unreadable store must
# not be rendered as a fact about the person.
sub display_names_block {
    my (@logins) = @_;
    my $r = display_names_for(@logins);
    return (
        display_names          => $r->{names},
        display_names_readable => ( $r->{readable} ? JSON::PP::true() : JSON::PP::false() ),
    );
}

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
# SM778/SM784: THE READ HAS FOUR ANSWERS AND THE HASH CARRIES TWO OF THEM.
#
# `read_settings` returns `{}` for a site that has never set a display name
# and `{}` for a store this process could not open. Every caller that turns
# that into a name gets '' either way, so "no name set" and "the engine could
# not tell" arrive at the page as one sentence - which is the collapse the
# release manager's four-states rule names, and the same one SM768 cost a
# release to find in the connector store.
#
# The hash cannot carry the difference (there is nowhere in `{}` to put it),
# so the READER records it beside the read and `settings_readable()` answers
# it. A file that is simply absent is READABLE: a site with no settings file
# has no display names, and that is an answer, not a failure. Anything else -
# a directory that will not open, a truncated file, unparseable JSON - is
# NOT, and a caller that means to render a name says so rather than showing
# a login as though nobody had ever given it a name.
#
# Errno is read BEFORE cannot_read, which calls getpwuid and clobbers $! -
# the exact ordering bug SM768 shipped.
{
    my %_settings_cache;
    my $_readable = 1;

    sub _settings_cache_clear { %_settings_cache = (); return }

    # 1 the settings are what the store says; 0 the store could not be read,
    # so an absent name is UNKNOWN rather than unset.
    sub settings_readable { return $_readable }

    sub read_settings {
        # SM778: a caller that never set $AUTH_DIR cannot be answered, and
        # asking anyway builds the path "/user-settings.json" out of an undef -
        # which warns onto stdout and, in a --json CLI, into the middle of the
        # document. NOT readable: the store was not established, which is a
        # different thing from being established as empty, and it also stops
        # write_settings from writing to a path made of nothing.
        unless ( defined $AUTH_DIR && length $AUTH_DIR ) {
            $_readable = 0;
            return {};
        }
        my $file = _settings_file();

        # SM770: the stat below serves the CACHE KEY and nothing else. It used
        # to double as an absence guard, so a store this process could not
        # search read as "no accounts" - which for a capability lookup means
        # "holds nothing", the exact shape SM760 cost a release to find.
        my @st  = stat $file;
        my $key = @st ? "$file:$st[9]:$st[7]" : '';
        if ( length $key && exists $_settings_cache{$key} ) {
            $_readable = 1;    # only a successful read is ever cached
            return $_settings_cache{$key};
        }
        # Raw octets for decode_json - same convention as read_group_settings
        # (ADR 0001); a non-ASCII email/comment used to kill the whole read.
        # SM770: through cannot_read, which names the file, the error AND the
        # unix user - the fact that turns "Permission denied" into an
        # instruction - and stays silent when the file is simply absent.
        open my $fh, '<:raw', $file or do {
            $_readable = $!{ENOENT} ? 1 : 0;    # errno first: cannot_read clobbers $!
            cannot_read( 'user-settings.json', $file );
            return {};
        };
        my $raw = do { local $/; <$fh> };
        close $fh;
        my $data = eval { JSON::PP::decode_json( $raw // '{}' ) };
        if ( !$data || ref $data ne 'HASH' ) {
            $_readable = 0;    # the file is there and says nothing we can use
            log_event( 'WARN', 'settings', 'user-settings.json unparseable; using defaults' );
            return {};
        }
        $_readable = 1;

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
# SM785: YOU MAY NOT OVERWRITE A STORE YOU COULD NOT READ.
#
# Every writer here is a read-modify-write: read the whole settings hash,
# change one account's entry, write the whole hash back. read_settings answers
# `{}` for a store it could not open - so the modify step built a hash
# containing ONE account and the write step made that true, destroying every
# other account's display name, comment, email, expiry, token TTL and start
# page. A rename needs no permission on the target file, only on the
# directory, so an unreadable store was not even a barrier.
#
# Found while building SM778: a test that made the store unreadable got back
# an EMPTY name map with `readable: 1`, because the failing read had been
# followed by touch_credential rewriting the file from `{}` - the store was
# genuinely empty by the time the second read succeeded. Token verification
# stamps "last used" on every call, so this fired on an ordinary API request.
#
# This is the release manager's four-states rule (SM784) at its most
# expensive: `{}` meaning "could not tell" was handed to a writer that read it
# as "there is nothing here", and the writer made the wrong answer true. The
# reader cannot fix it alone - it has nowhere in `{}` to put the difference -
# so the WRITER asks whether the read that produced its argument succeeded.
#
# Refusing is safe in both directions: a store that is simply ABSENT reads as
# readable (ENOENT is an ordinary state), so a first write still lands.
sub write_settings {
    my ($data) = @_;
    my $file = _settings_file();
    unless ( settings_readable() ) {
        log_event( 'WARN', 'settings',
            'refusing to write user settings over a store that could not be read',
            file => $file );
        die "Refusing to overwrite $file: it could not be read, so this write "
            . "would replace every account's settings with the one being changed. "
            . "Fix the permissions on the file (and its directory) and retry.\n";
    }
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
