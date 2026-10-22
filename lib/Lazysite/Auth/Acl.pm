package Lazysite::Auth::Acl;

# SM074 per-file ACL store (lazysite/auth/acls.json) and the ownership/allow
# checks, shared (SM079). Context is $DOCROOT, set by the script. The
# operator-bypass decision (_is_operator) is request-context-bound and stays in
# the manager, which combines it with _acl_allows here.

use strict;
use warnings;
use JSON::PP                 ();
use File::Path               qw(make_path);
use File::Basename           qw(dirname);
use Lazysite::Auth::Identity ();    # SM1131: the one reader of the request's groups
use Lazysite::Util ();    # SM289: secure_write_perms - root must not own this store
use Exporter 'import';
use Lazysite::Paths ();

# DA-19: loaded once at the top rather than `require`d in four subs.
# Settings depends only on Lazysite::Util, so there is no cycle back here.
use Lazysite::Auth::Settings ();

our @EXPORT_OK = qw(load_acls save_acls _acl_norm _to_list _acl_allows _acls_path
    _is_operator _acl_denied groups_for_user may_read_any_rule file_rule_bypass
    account_is_operator group_confers_operator
    gating_for root_gating placement_for relocating_key address_denial address_chain);

our $DOCROOT;    # set by the script

# SM293: this site's engine tree - beside the docroot once migrated,
# inside it before. Asked, never computed, so both layouts work on one
# code path and a site migrates by moving the directory.
sub _lz { return Lazysite::Paths::lazysite_dir($DOCROOT) }

# Manager auth-state, set per request by the dispatcher (the sysop-bypass
# decision). A token client is never a sysop; otherwise group-granted
# capabilities decide (SM138: the conf manager_groups fallback is retired).
our $auth_user  = '';
our $token_auth = 0;

# SM077: the requesting user's groups (for @group ACL entries), set per request
# by the dispatcher.
#
# WHAT EACH CHANNEL SETS - they do not agree, and this comment used to claim
# they did ("a token/WebDAV partner carries none"), which is false for WebDAV
# and was copied into the architecture doc and believed for a year:
#
#   lazysite-dav.pl         user_groups_for($user) - the account's REAL groups,
#                           so an @group entry DOES match a WebDAV partner
#   lazysite-mcp.pl         () - hard-zeroed, so an @group never matches
#   lazysite-manager-api.pl HTTP_X_REMOTE_GROUPS - the session's groups for a
#                           cookie client, empty for a token client
#
# SM288 made them agree. Every channel now assigns this from groups_for_user()
# below, except the manager's COOKIE path, which uses the session's groups from
# X-Remote-Groups as set by the auth wrapper. t/lint/35 pins that, because the
# previous state - dav resolving real groups, mcp hard-zeroing them, the token
# path reading a header a token cannot carry - was invisible until an operator
# said so.
our @user_groups;

# THE per-account group resolver for the ACL decision, on every channel.
#
# Before SM288 there were three answers: lazysite-dav.pl read the group file
# itself, lazysite-mcp.pl set the empty list with a comment calling it "the safe
# default", and lazysite-manager-api.pl took X-Remote-Groups - which a token
# client structurally cannot send. So the same account, in the same group,
# reading the same file under the same ACL, was ALLOWED over WebDAV and REFUSED
# over MCP. A group is a property of the account, not of the door it arrived
# through.
#
# Delegates to Settings::effective_groups, which is what the capability and
# domain-access resolvers already use, so "which groups is this user in" has one
# implementation for every question lazysite asks. AUTH_DIR is localised from
# this module's own request context - the same trick _groups_grant_cap uses
# below - so a caller that only sets Acl::DOCROOT needs to know nothing else.
sub groups_for_user {
    my ($user) = @_;
    return () unless defined $user    && length $user;
    return () unless defined $DOCROOT && length $DOCROOT;
    local $Lazysite::Auth::Settings::AUTH_DIR = _settings_dir();
    return Lazysite::Auth::Settings::effective_groups($user);
}

sub _acls_path { _lz() . "/auth/acls.json" }

# The directory Settings reads its stores from, for this module's request
# context. Four subs localise $Lazysite::Auth::Settings::AUTH_DIR to it so a
# caller that sets only Acl::DOCROOT needs to know nothing else; `local`
# belongs to the caller's scope, so this supplies the value, not the binding.
sub _settings_dir { return _lz() . "/auth" }

# SM901: the auth store's directory, for a caller in another module that has
# to localise Auth::Settings::AUTH_DIR the way the resolvers here do
# (Manager::Files checks a rule's names against the accounts and groups).
sub settings_dir { return _settings_dir() }

# A caller's own copy of the map. load_acls has ALWAYS handed back a fresh
# structure - it decoded the file on every call - and several callers rely on
# that: acl_drop_tree and acl_move_tree here, and the manager's acl actions,
# mutate what they were given before saving it. The memo below would otherwise
# hand every caller the same reference, and a mutation whose save FAILED would
# leave the process answering from a map that never reached the file.
sub _acls_copy {
    my ($m) = @_;
    my %out;
    for my $k ( keys %{$m} ) {
        my $e = $m->{$k};
        if ( ref $e eq 'HASH' ) {
            $out{$k} = {
                map {
                    $_ => (
                        ref $e->{$_} eq 'ARRAY' ? [ @{ $e->{$_} } ] : $e->{$_} )
                } keys %{$e}
            };
        }
        else {
            $out{$k} = $e;
        }
    }
    return \%out;
}

# MEMOISED ON (path, mtime, size), with the one-second guard (DAO-4). This file
# is read once per binding per visitor - Access::may_read reaches _acl_allows,
# which reaches here - and the JSON decode is pure Perl.
#
# HOW STALENESS IS PREVENTED:
#
#   1. save_acls replaces the file by rename, so mtime (and almost always
#      size) changes, and the key with it. A rule saved by another process is
#      seen by this one on the next read.
#   2. THE ONE-SECOND GUARD covers a same-second rewrite of the same length -
#      swapping one three-letter username for another does exactly that - which
#      would otherwise carry an identical key. mtime is one-second granular, so
#      a file younger than a second is read fresh every time.
#   3. save_acls clears this process's memo, because the (mtime,size) key
#      cannot see OUR OWN write within the granularity of the clock, and the
#      write and the next authorisation can be milliseconds apart. Same
#      reasoning as SM334's _settings_cache_clear.
#   4. Every caller gets its own copy, so a caller that mutates the map -
#      several do - cannot change what the next caller reads.
#
# This is an access-control store, so none of these four is decorative.
#
# SM1024 (ruled 2026-10-12, "Close all three"): THE ANSWER CARRIES ITS FOURTH
# STATE. load_acls still answers {} for a store that exists and will not open
# or will not decode - its callers that list or edit rules want a map - but it
# now records that in $ACLS_FAULT, and the per-file check (_acl_allows, and
# _acl_denied's refusal) reads it: a broken store is not "no rules", so a
# non-operator is refused until it is repaired. The operator is unaffected
# (_acl_denied asks _is_operator first), which keeps the repair in reach from
# the manager. An ABSENT store is an answer: no rules.
our $ACLS_FAULT = 0;

{
    my %_acls_cache;

    sub _acls_cache_clear { %_acls_cache = (); return }

    sub load_acls {
        my $path = _acls_path();

        # SM770: no `-f` guard. A stat this process may not make fails exactly
        # as an open it may not make, and the guard turned that into "no rules"
        # before the open could report it. An absent file still reads as {} -
        # through the open's ENOENT, which cannot_read passes over in silence.
        $ACLS_FAULT = 0;
        my @st  = stat $path;
        my $key = @st ? "$path:$st[9]:$st[7]" : '';
        return _acls_copy( $_acls_cache{$key} )
            if length $key && exists $_acls_cache{$key};

        open my $fh, '<', $path or do {
            $ACLS_FAULT = $!{ENOENT} ? 0 : 1;    # errno first: cannot_read clobbers $!
            return ( Lazysite::Util::cannot_read( 'acls', $path ) // {} );
        };
        my $raw = do { local $/; <$fh> };
        close $fh;
        my $m = eval { JSON::PP::decode_json( $raw // '{}' ) };
        unless ( ref $m eq 'HASH' ) {
            $ACLS_FAULT = 1;
            Lazysite::Util::log_event( 'WARN', 'acl',
                'acls.json does not decode as a JSON object - every per-file check by a '
                    . 'non-operator is refused until it is repaired',
                file => 'lazysite/auth/acls.json' );
            return {};
        }

        if ( length $key && @st && $st[9] < time() - 1 ) {
            %_acls_cache = () if keys %_acls_cache > 8;
            $_acls_cache{$key} = $m;
            return _acls_copy($m);
        }
        return $m;
    }
}

sub save_acls {
    my ($map) = @_;
    my $path  = _acls_path();
    my $dir   = dirname($path);
    make_path($dir) unless -d $dir;
    my $tmp = "$path.tmp.$$";
    open my $fh, '>', $tmp or return 0;
    print {$fh} JSON::PP->new->canonical->pretty->encode($map);
    close $fh;

    # SM215/SM289: never leave a root-owned acls.json behind.
    #
    # Every writer of this store used to be a CGI running as the site user, so a
    # bare chmod was enough. SM289 added a CLI verb, and root is a plausible
    # caller of a CLI - at which point a plain write leaves a file the CGI can no
    # longer update, and the manager silently loses the ability to change
    # permissions. That is the Class-B ownership drift SM215 fixed everywhere
    # else; this store was missed because nothing could reach it as root.
    #
    # secure_write_perms makes the file match its directory's owner and group,
    # which is the provisioned site user in every install shape.
    #
    # SM428: 0660, NOT 0640 - GROUP-WRITABLE.
    #
    # This store is written by TWO identities on a group-shared docroot: the
    # site user (CLI verbs, `acl reapply`) and the www-data CGI (the manager's
    # permissions UI). 0640 leaves it readable but not writable by the other
    # one, so whichever identity wrote it last takes the file away from the
    # other - and `lazysite check` says so in terms: "acls.json ... is not
    # writable by the CGI (www-data) - the manager cannot save it".
    #
    # It was reaching the field on EVERY DEPLOY. The upgrade's `acl reapply`
    # step rewrote the store as the site user, dropping it to 0640, and the
    # health pass that follows repaired it back to 0660 - so the defect was
    # invisible in the log except as a repair that ran every single time. A
    # repair that always runs is not a repair; it is a writer disagreeing with
    # its own checker, once per deploy, with a window in between where the
    # manager silently cannot save a permission change.
    #
    # 0660 matches the other auth files the same check requires group-write on
    # (users, groups) and matches the 2770 setgid directory they live in.
    # Nothing world-readable either way.
    Lazysite::Util::secure_write_perms( $tmp, oct '660' );
    my $ok = rename $tmp, $path;

    # DAO-4: this process must not answer from a memo it has just
    # superseded. The (mtime,size) key handles another process's write; this
    # handles our own, which is the case where a permission change and the
    # next authorisation are milliseconds apart.
    _acls_cache_clear();
    return $ok;
}

# --- CF-2: the ACL lifecycle, in one place -----------------------------------
#
# Deleting content must drop its rules; moving content must carry them. Both
# were true on ONE surface each and false on the other, in opposite directions:
# DAV's DELETE dropped entries and the manager's did not; the manager's move
# re-keyed and DAV's did not. The comment at lazysite-dav.pl claiming "the
# manager's delete has always done this" was simply wrong, so SM212's fix never
# reached the manager, MCP or the control API.
#
# The move half is the one with a confidentiality consequence. WebDAV resolves
# a gated path into the PRIVATE store, so a MOVE to an ungated destination
# physically relocates the bytes into the public docroot - and with no re-key,
# no rule follows them. Protected content becomes public through an ordinary
# operation, with no error and nothing to notice. That is the exact inverse of
# SM286: protecting content moves it, so moving content has to carry its
# protection.
#
# One definition here rather than four copies, because four copies is how the
# two surfaces came to disagree in the first place.

# Drop the entry for $key and every entry beneath it. Returns the number
# removed; saves only if something changed.
sub forget_path {
    my ($key) = @_;
    $key = _acl_norm($key);
    return 0 unless defined $key && length $key;
    my $acls    = load_acls();
    my $removed = 0;
    for my $k ( keys %$acls ) {
        next unless $k eq $key || index( $k, "$key/" ) == 0;
        delete $acls->{$k};
        $removed++;
    }
    return 0 unless $removed;
    save_acls($acls) or return 0;
    return $removed;
}

# Move the entry for $from to $to, with its descendants. Returns the number
# re-keyed.
#
# The STORE SYNC is deliberately the caller's, immediately after: the rule and
# the bytes must both move, but where the bytes go is a private-store decision
# with its own companions (the .brief sidecar, the stale render cache) that
# belongs with the mover rather than with the key. Every caller of this
# function must follow it with a sync against the NEW key - which settles both
# directions at once, into a gated folder and back out of one.
sub rekey_path {
    my ( $from, $to ) = @_;
    $from = _acl_norm($from);
    $to   = _acl_norm($to);
    return 0 unless defined $from && length $from && defined $to && length $to;
    return 0 if $from eq $to;

    my $acls  = load_acls();
    my $moved = 0;
    for my $k ( sort keys %$acls ) {
        my $nk;
        if    ( $k eq $from )                { $nk = $to }
        elsif ( index( $k, "$from/" ) == 0 ) { $nk = $to . substr( $k, length $from ) }
        else                                 { next }
        $acls->{$nk} = delete $acls->{$k};
        $moved++;
    }
    return 0 unless $moved;
    save_acls($acls) or return 0;
    return $moved;
}

# Strip leading slashes so an ACL key matches the manager's relative paths.
sub _acl_norm { my $r = shift; $r =~ s{^/+}{} if defined $r; return $r }

# Normalise a list value (arrayref or comma/space string) to an arrayref,
# or undef if not provided.
sub _to_list {
    my ($v) = @_;
    return undef unless defined $v;
    return [ grep { length } @$v ] if ref $v eq 'ARRAY';
    return [ grep { length } split /[,\s]+/, $v ];
}

# Does the ACL for $rel allow $user $mode access? No entry = allowed (the
# account's scope governs); owner always allowed; else membership of the
# mode's allow-list.
# SM268 H3: which entry governs $rel for $mode - exact, then the section's own
# landing page, then the LONGEST matching folder prefix.
#
# Folder scope was implemented only in the processor's module-free copy, so a
# "protected section" was protected on the anonymous read path and nowhere else:
# Acl::_acl_allows matched the exact key only, and the manager, MCP and WebDAV
# therefore granted full READ AND WRITE inside a section the sysop had gated.
# An adversarial review demonstrated it. One store answering two different
# questions depending on which surface asks is precisely what SM223 chose a
# single store to avoid.
#
# Only entries carrying a non-empty list for the mode participate, so an
# owner-only entry - which action_copy writes for every duplicated file - cannot
# beat an enclosing folder rule. It is not a tighter rule, it is no rule.
# SM936 AO2: ONE WALK, AND IT CAN ALSO SAY WHICH KEY WON.
#
# AO2 needs the KEY that governs a path, not just the entry - "there is a rule
# somewhere above you" is the half that costs an author the time. The precedence
# here is not trivial (exact key, then the extensionless stem, then the LONGEST
# ancestor prefix, then the three site-wide spellings, weakest last), so a second
# function that found the key by walking it again would be a second definition of
# precedence. They would agree until one changed.
#
# So the walk returns BOTH and the two public questions are thin wrappers over
# it. _acl_entry_for keeps its signature and its callers, which are many.
sub _acl_entry_for {
    my ( $map, $rel, $mode ) = @_;
    my ($e) = _acl_entry_and_key( $map, $rel, $mode );
    return $e;
}

# The KEY whose rule governs $rel for $mode, or undef. Public because AO2 reports
# it to whoever just created a page under it.
# ($docroot, $rel, $mode?) - THE SAME SHAPE AS gating_for, deliberately. These
# are the two halves of one question ("is this gated, and by what?") and giving
# them different signatures is how a caller passes one argument to a
# two-argument sub and reads the resulting undef as an answer. That happened
# while measuring this filing: gating_for called with one argument returned a
# flat 'unknown' for every case and looked like a finding.
sub governing_key {
    my ( $docroot, $rel, $mode ) = @_;
    return undef unless defined $rel && length $rel;
    local $DOCROOT = ( defined $docroot && length $docroot ) ? $docroot : $DOCROOT;
    my ( undef, $key ) = _acl_entry_and_key( load_acls(), $rel, ( $mode // 'read' ) );
    return $key;
}

sub _acl_entry_and_key {
    my ( $map, $rel, $mode ) = @_;
    $rel = _acl_norm($rel) // '';

    my $governs = sub {
        my ($e) = @_;
        return 0 unless ref $e eq 'HASH';
        return 1 unless defined $mode && length $mode;
        # SM1242: `draft` is a flag, not a list - the processor's draft mode
        # (lazysite-processor/acl.pm, SM981): only an entry carrying it decides.
        return ( $e->{draft} ? 1 : 0 ) if $mode eq 'draft';
        return ( ref $e->{$mode} eq 'ARRAY' && @{ $e->{$mode} } ) ? 1 : 0;
    };

    return ( $map->{$rel}, $rel ) if $governs->( $map->{$rel} );

    if ( $rel =~ m{\A(.+)\.(?:md|url|html)\z} ) {
        my $stem = $1;
        return ( $map->{$stem}, $stem ) if $governs->( $map->{$stem} );
    }

    my $best;
    my $best_key;
    my $best_len = -1;
    for my $k ( keys %$map ) {
        next unless $governs->( $map->{$k} );
        ( my $p = $k ) =~ s{\A/+}{};
        $p =~ s{/+\z}{};
        next unless length $p;
        next unless index( $rel, "$p/" ) == 0;
        next unless length($p) > $best_len;
        $best     = $map->{$k};
        $best_key = $k;
        $best_len = length $p;
    }
    return ( $best, $best_key ) if $best;

    # SM287: the SITE-WIDE rule, and it is the WEAKEST - checked only when
    # nothing more specific governs, so a public carve-out inside a private site
    # stays expressible (which is the common shape: everything private except
    # the landing page).
    #
    # Before this, a root entry did nothing under any spelling. Not by an
    # oversight in one branch: the loop above skips a zero-length prefix, and
    # even without that guard `index($rel, "$p/")` can never match an empty
    # prefix because _acl_norm has already stripped the leading slash from $rel.
    # So there was NO way to say "this whole site is private" - auth_default
    # governs pages and deliberately does not reach statics, and enumerating
    # top-level folders fails OPEN as content grows.
    #
    # '/' is what the writer stores. '' and '.' are accepted too: a hand-edited
    # store is a real interface here and all three plainly mean the same thing.
    # Glob spellings are NOT accepted - the store has no matching language, and
    # audit_site's acl_keys_matching_nothing surfaces a key that governs nothing.
    for my $rk ( '/', '', '.' ) {
        return ( $map->{$rk}, $rk ) if $governs->( $map->{$rk} );
    }
    return;
}

# SM881: IS THIS PATH GATED? THE ENGINE'S ONE ANSWER, FOR PLUGINS TO ASK.
#
# Ruled by the release manager on 2026-09-14: the ACL read lives in the engine as
# one supported answer that plugins call, not as a private read inside whichever
# plugin needs it next. The precedence this depends on already existed and was
# simply not reachable - `_acl_entry_for` has answered "which rule governs this
# path?" with the full ladder (exact key, then the .md/.url/.html stem, then the
# longest ancestor prefix, then the site-wide key) since SM287, and was never in
# @EXPORT_OK. So this promotes an existing private answer rather than designing a
# new one.
#
# THIS IS NOT A SECOND resolve_for_write, and the names will invite that reading.
# `Private::resolve_for_write` answers "where should I write this?" from DOCROOT
# EVIDENCE - an ancestor that exists in the docroot settles it public. That is
# correct for its job and useless after a git merge, because the merge has just
# created the ancestor it reads. This answers "is this path gated?" from the ACL
# STORE, which a merge does not touch. Different question, different evidence.
#
# THREE STATES, NOT A BOOLEAN, and this is the part that must not be simplified.
# The processor's `_acl_governed` returns 1 when the store will not load, which is
# right for a READ: if we cannot tell, refuse to serve. A caller that MOVES files
# inverts that consequence - an unparseable store would mean "relocate every
# changed file into the private store", silently unpublishing a site's content on
# the next pull, which is worse than the exposure being fixed. So "could not tell"
# is its own answer and a mover must stop on it.
#
#   'gated'    a rule governs this path with a non-empty read list
#   'open'     no rule governs it, or there are no rules at all
#   'unknown'  the store exists and could not be read or parsed
#
# WHY NOT load_acls. It answers {} for BOTH an absent store and an unreadable
# one - deliberately, because its callers want "no rules" either way. Reusing it
# here would collapse the very distinction this function exists to draw, so this
# reads the file itself. That is the only duplication, and it buys the third
# state.
#
# READ GATING ONLY, and deliberately. A `draft` entry carrying no read list
# answers 'open', because a draft section already 404s to an anonymous visitor -
# so a file pulled into one is not exposed and does not belong in the private
# store. One question, one answer; a resolver that folded in draftness would be
# answering two.
# The store read both answers share, with the two failures told apart.
#
# NO STAT GUARD IN FRONT OF IT - SM770's rule, and t/lint/121 caught the first
# version of this for breaking it. The rule is the same one this tri-state exists
# for, one level up: a stat this process may not make fails exactly as an open it
# may not make, so `return 'open' unless -e $path` renders a permissions fault as
# "no rules" before the open can report it. That is the exposure, arrived at by a
# different route. The open decides, and `$!` says which failure it was.
sub _acl_map_or_state {
    my $path = _acls_path();
    open my $fh, '<:raw', $path or do {

        # ENOENT is an answer: this site has no rules. Anything else is a fault,
        # and cannot_read logs it - silently passing over ENOENT, which is why
        # the flag is read before the call rather than after.
        my $absent = $!{ENOENT} ? 1 : 0;
        Lazysite::Util::cannot_read( 'acls', $path );
        return ( undef, $absent ? 'open' : 'unknown' );
    };
    my $raw = do { local $/; <$fh> };
    close $fh;
    return ( undef, 'unknown' ) unless defined $raw;

    my $map = eval { JSON::PP::decode_json( length $raw ? $raw : '{}' ) };
    return ( undef, 'unknown' ) unless ref $map eq 'HASH';
    return ( $map,  '' );
}

sub gating_for {
    my ( $docroot, $rel ) = @_;
    return 'unknown' unless defined $rel && length $rel;
    local $DOCROOT = ( defined $docroot && length $docroot ) ? $docroot : $DOCROOT;

    my ( $map, $state ) = _acl_map_or_state();
    return $state unless ref $map eq 'HASH';

    return _acl_entry_for( $map, $rel, 'read' ) ? 'gated' : 'open';
}

# SM1046 D-2: the rule keys that touch a folder - the folder's own, any below
# it, and any above it (a site-wide rule included) - or undef when the store
# cannot be read. Every mode counts: a write rule is as much a decision about
# who may act there as a read rule. The open decides, as in gating_for.
sub rule_keys_touching {
    my ( $docroot, $rel ) = @_;
    return undef unless defined $rel && length $rel;
    local $DOCROOT = ( defined $docroot && length $docroot ) ? $docroot : $DOCROOT;
    my ( $map, $state ) = _acl_map_or_state();
    return [] if !ref $map && $state eq 'open';    # no store: no rules
    return undef unless ref $map eq 'HASH';
    my $r = _acl_norm($rel) // '';
    $r =~ s{/+\z}{};
    my @keys;
    for my $k ( sort keys %{$map} ) {
        my $n = _acl_norm($k) // '';
        $n =~ s{/+\z}{};
        $n = '' if $n eq '.';
        push @keys, $k
            if $n eq ''
            || $n eq $r
            || index( "$n/", "$r/" ) == 0
            || index( "$r/", "$n/" ) == 0;
    }
    return \@keys;
}

# SM981 (ruled 2026-10-11, "Land where save would"): WHICH TREE DO THIS PATH'S
# BYTES BELONG IN, by the rules - 'private', 'public', or 'unknown' (the store
# exists and cannot be read; a mover must not move on that, as gating_for says).
#
# A rule RELOCATES content when it carries a read list or `draft` (SM286: setting
# either moves the section out of the document root; the site-wide rule never
# does - the docroot cannot be moved into its own sibling). The bytes of a path
# belong in the private store when ANY rule that governs it relocates: its own,
# its page stem's (a folder's rule covers its landing page, SM268 H14), or an
# ancestor folder's.
#
# Why not gating_for: that answers READ gating only, and a draft section with no
# read list relocates too. Why not the path's own record: that is the defect.
# The movers judged placement by the moved path's OWN rule, so a file carrying an
# owner-only rule (every copy gets one) moved INTO a draft or read-gated folder
# was moved OUT of the store again - "this rule does not gate" - and landed in the
# document root, where a front end serves it; a draft folder with no read list
# then served it to anyone, because the owner-only entry also hid the folder's
# draft flag from the processor. Owner and write lists say who edits; they say
# nothing about where the bytes live.
sub placement_for {
    my ( $docroot, $rel ) = @_;
    return 'unknown' unless defined $rel;
    local $DOCROOT = ( defined $docroot && length $docroot ) ? $docroot : $DOCROOT;
    my ( $map, $state ) = _acl_map_or_state();
    return ( $state eq 'open' ? 'public' : 'unknown' ) unless ref $map eq 'HASH';
    return relocating_key( $map, $rel ) ? 'private' : 'public';
}

# The key of a rule that relocates $rel's content (see placement_for), or undef.
# The nearest is returned, for a caller that names it; any one decides.
sub relocating_key {
    my ( $map, $rel ) = @_;
    $rel = _acl_norm($rel) // '';
    $rel =~ s{/+\z}{};
    return undef unless length $rel;
    my $stem = $rel =~ m{\A(.+)\.(?:md|url|html)\z} ? $1 : undef;
    my ( $best, $best_len );
    for my $k ( keys %$map ) {
        my $e = $map->{$k};
        next unless ref $e eq 'HASH';
        next unless $e->{draft} || ( ref $e->{read} eq 'ARRAY' && @{ $e->{read} } );
        ( my $p = $k ) =~ s{\A/+}{};
        $p =~ s{/+\z}{};
        next unless length $p;    # the site-wide rule relocates nothing
        next unless $p eq $rel
            || ( defined $stem && $p eq $stem )
            || index( $rel, "$p/" ) == 0;
        next if defined $best_len && length($p) <= $best_len;
        ( $best, $best_len ) = ( $k, length $p );
    }
    return $best;
}

# SM882: is EVERY page under this root gated? The invariant the release manager
# ruled on the same day - a fully gated content root contains nothing public - is
# only checkable if something can answer this, and it is the same store read.
#
# Answers on the ROOT KEY alone, which is what makes it cheap and honest: a site
# is fully gated when a site-wide rule gates it, not when somebody has gated every
# folder one at a time. The second shape is indistinguishable from an incomplete
# job and would have this report an invariant the operator never declared.
sub root_gating {
    my ($docroot) = @_;
    local $DOCROOT = ( defined $docroot && length $docroot ) ? $docroot : $DOCROOT;

    my ( $map, $state ) = _acl_map_or_state();
    return $state unless ref $map eq 'HASH';

    for my $rk ( '/', '', '.' ) {
        my $e = $map->{$rk};
        next unless ref $e eq 'HASH';
        return 'gated' if ref $e->{read} eq 'ARRAY' && @{ $e->{read} };
    }
    return 'open';
}

sub _acl_allows {
    my ( $rel, $mode, $user ) = @_;
    my $map = load_acls();
    return 0 if $ACLS_FAULT;    # SM1024: a broken store is not "no rules"
    my $a = _acl_entry_for( $map, $rel, $mode );
    return 1 unless $a;
    return 1 if defined $a->{owner} && defined $user && $a->{owner} eq $user;
    my $list = $a->{$mode};
    return 1 unless ref $list eq 'ARRAY' && @$list;
    # SM268 01-L1: case-insensitive, and compound-expanded - the same semantics
    # the processor's copy uses (t/lint/31 pins the pair) and the same ones
    # check_auth applies to `groups:` front matter. Three different answers to
    # "is this user in that group" on one request was the defect.
    my %grp = map { lc($_) => 1 }
        do {
        local $Lazysite::Auth::Settings::AUTH_DIR = _settings_dir();
        Lazysite::Auth::Settings::group_closure(@user_groups);
        };
    for my $entry (@$list) {
        next unless defined $entry && length $entry;
        if ( $entry =~ /\A\@(.+)\z/ ) {    # SM077: @group entry
            return 1 if $grp{ lc $1 };
        }
        elsif ( defined $user && $entry eq $user ) {
            return 1;
        }
    }
    return 0;
}

# Operator bypass (manager-only). A token (control-API) client is NEVER an
# sysop - per-file ACL ownership applies to it like any WebDAV partner. An
# unsecured site (no manager_groups) treats cookie clients as sysops; the
# 'local' user is always sysop; else manager-group membership decides. The
# token path never consults the client-influenceable X-Remote-Groups.
# SM095: does any of these groups carry capability $cap? Routed through the
# shared resolver helper (ADR 0001) - AUTH_DIR localised from this module's
# request context so callers that only set Acl::DOCROOT keep working.
sub _groups_grant_cap {
    my ( $cap, @groups ) = @_;
    return 0 unless @groups;
    local $Lazysite::Auth::Settings::AUTH_DIR = _settings_dir();
    return Lazysite::Auth::Settings::groups_grant_cap( $cap, @groups );
}

sub _is_operator {
    return 0 if $token_auth;
    return 1 if ( $auth_user // '' ) eq 'local';

    local $Lazysite::Auth::Settings::AUTH_DIR = _settings_dir();

    # SM095/SM138: unrestricted account management is the manage_users
    # capability, granted through a group. The legacy lazysite.conf
    # manager_groups fallback is RETIRED - the migration granted those groups
    # their capabilities explicitly.
    #
    # SM268 02-7: ask the STORE FIRST, then the header - not the header alone.
    #
    # The two sources disagree for a session whose group set changed after the
    # header was written, and the header is the stale one. Asking the store
    # first means a grant that exists NOW is honoured now, which is the
    # direction that matters: it is how a revoked grant stops applying and a
    # fresh one starts.
    #
    # The header is NOT dropped, though the review suggested it. It carries
    # group names for identities the local store does not know - a trusted
    # reverse proxy or SSO, where membership lives in the IdP and the account
    # may not exist here at all. t/unit/manager/16 asserts exactly that case
    # (an operator known only as X-Remote-Groups: managers), so removing the
    # header check trades a LOW consistency finding for a broken deployment.
    # It reaches this code only when the wrapper set LAZYSITE_AUTH_TRUSTED, so
    # it is vouched for; the remaining objection was staleness, and consulting
    # the store first is what answers that.
    #
    # SM991 (ruled 2026-10-12, "Operators bypass, others bound"): the OPERATOR
    # is a member of the operator group (Settings::groups_are_operator - the
    # group carrying the `manager` flag, which setup-sysop creates), not a
    # holder of manage_users. manage_users is user and group management; it
    # passed every capability gate on the manager because this asked for it,
    # so a group made to approve account requests could also set config.
    if ( defined $auth_user && length $auth_user ) {
        return 1 if eval { Lazysite::Auth::Settings::account_is_operator($auth_user) };
    }
    # SM1131: the one identity reader (configured header names, one separator,
    # directory names mapped), not a read of the fixed X-Remote-Groups here.
    # SM1135: a group a trusted proxy named counts toward operator status only if the
    # operator marked it `directory_grants` (R1); a cookie identity is unfiltered.
    my @ug = Lazysite::Auth::Settings::request_cap_groups(
        Lazysite::Auth::Identity::request_identity( ( defined $DOCROOT ? ( lazysite_dir => _lz() ) : () ) ) );
    return 1 if @ug && Lazysite::Auth::Settings::groups_are_operator(@ug);

    # A site where no group grants manager access at all is unsecured/dev: any
    # authenticated user is an operator.
    return 1 unless Lazysite::Auth::Settings::site_grants_manager();
    return 0;
}

# SM464: may this caller READ any rule - the audit half of ownership, split
# from the right to modify.
#
# Ownership stays absolute for WRITES: acl-set on somebody else's rule is
# refused whoever asks, and nothing here touches that. But the person
# accountable for an estate's access control is precisely the person who did
# not set most of its rules, and the measured workarounds - take ownership
# (which CHANGES the rule under inspection) or read the store off disk (which
# bypasses everything and leaves no trace) - are worse than the read they
# route around.
#
# Who reads: an operator or a cookie-session holder of manage_users - and a TOKEN whose OWN GRANT carries
# manage_users. _is_operator refuses every token by design (a token is never
# an operator), and that stays; the token override is deliberately keyed on
# the grant the operator wrote for that partner, not on the account's group
# memberships, so holding it is an explicit per-grant decision and never a
# side effect of a group intended for the cookie UI (SM127).
our %token_caps;    # the token's OWN grant settings; set by the API/MCP entry
sub may_read_any_rule {
    return 1 if _is_operator();
    return 1 if $token_auth && $token_caps{manage_users};
    # SM991: a cookie holder of manage_users is no longer the operator, and
    # reading any rule was granted to it by name (above) - SM464's audit half
    # stays with the capability rather than leaving with the operator.
    if ( !$token_auth && defined $auth_user && length $auth_user ) {
        local $Lazysite::Auth::Settings::AUTH_DIR = _settings_dir();
        my $caps = eval { Lazysite::Auth::Settings::caps_for($auth_user) } || {};
        return 1 if $caps->{manage_users};
    }
    return 0;
}

# SM979: WHO PASSES A FILE'S RULE WITHOUT BEING NAMED IN IT - the sysadmin
# ('local', the CLI's break-glass identity) and, on an unsecured site where no
# group grants manager access, every signed-in account (the dev/first-run mode
# _is_operator also honours). Nobody else, and in particular NOT a holder of
# manage_users.
#
# _is_operator() answers "may this account manage accounts and pass the
# manager's capability gates", and its clause for manage_users was taken to be
# right for that (SM991 removed it). It was ALSO the per-file bypass, so a group holding manage_users and
# nothing else - made to approve account requests - saved a page at the site
# root and overwrote another author's post through `save`, past rules that
# named neither it nor its group, while `group-reach` said it could call
# nothing. A file's rule is the file owner's statement of who writes it;
# account management is a different authority and does not include it. A
# sysop group reaches a file the way any group does: by being named in its
# rule (the starter's rules name @sysops), or by the CLI as `local`.
#
# A token is never bypassed, as before: per-file rules bind every partner.
#
# SM991 (ruled 2026-10-12, "Operators bypass, others bound"): and a member of
# the OPERATOR GROUP - which is what _is_operator now answers, so the two are
# one test again. What SM979 took away was the bypass for manage_users; the
# operator keeps the one it had, and manage_users, approve_accounts and every
# other grant stay bound by the rule.
sub file_rule_bypass {
    return _is_operator() ? 1 : 0;
}

# SM991: is this ACCOUNT, or is any member of this GROUP, the operator? For the
# manager's users API, which refuses a non-operator any change to the operator's
# account or the operator group (Manager::Users).
sub account_is_operator {
    my ($user) = @_;
    local $Lazysite::Auth::Settings::AUTH_DIR = _settings_dir();
    return Lazysite::Auth::Settings::account_is_operator($user) ? 1 : 0;
}

sub group_confers_operator {
    my ($group) = @_;
    return 0 unless defined $group && length $group;
    local $Lazysite::Auth::Settings::AUTH_DIR = _settings_dir();
    return Lazysite::Auth::Settings::groups_are_operator($group) ? 1 : 0;
}

# SM1139 (slice B of SM1134): THE ADDRESS RULE, for the doors that are not the
# processor - the manager API, MCP and WebDAV read and write files through
# _acl_denied / WebDAV's authorise, and a file under an address rule is limited by
# the address wherever it is reached. The processor decides the same question in
# lazysite-processor/acl.pm (_address_chain, _address_refused) on the render path,
# which cannot load this tree up front (ADR 0001); t/unit/processor/140 holds the
# two chains and the sentence to the same answers.
#
# THE LAYERS. Every acls.json entry that names an address list for $rel - its own
# key, its page stem's, each ancestor folder's, the site-wide rule - is one layer.
# Each layer is decided alone by Lazysite::Auth::AddressLists::decide (the address
# in one of its allow lists, in none of its deny lists) and EVERY layer must admit:
# AND across layers, OR within one, deny wins. See the processor's note for why this
# is not the longest-match rule the read lists use.
sub address_chain {
    my ( $map, $rel ) = @_;
    return [] unless ref $map eq 'HASH' && defined $rel;
    $rel = _acl_norm($rel) // '';
    $rel =~ s{/+\z}{};
    my $stem = $rel =~ m{\A(.+)\.(?:md|url|html)\z} ? $1 : undef;
    my ( @own, @stem, @above, @site );
    for my $k ( sort keys %$map ) {
        my $e = $map->{$k};
        next unless ref $e eq 'HASH';
        my $allow = ref $e->{addresses} eq 'ARRAY' ? [ grep { defined && !ref } @{ $e->{addresses} } ] : [];
        my $deny = ref $e->{addresses_deny} eq 'ARRAY' ? [ grep { defined && !ref } @{ $e->{addresses_deny} } ] : [];
        next unless @$allow || @$deny;
        # The same spellings the processor's chain takes (t/unit/processor/140): the
        # key as written, leading slashes off, is the path's own (or its stem's); a
        # folder is the key with trailing slashes off and a `/` after it; the
        # site-wide rule is '/', '' or '.'.
        ( my $kn = $k )  =~ s{\A/+}{};
        ( my $p  = $kn ) =~ s{/+\z}{};
        my $layer = { key => $k, allow => $allow, deny => $deny };
        if    ( $kn eq '' || $kn eq '.' )                { push @site,  $layer }
        elsif ( $kn eq $rel )                            { push @own,   $layer }
        elsif ( defined $stem && $kn eq $stem )          { push @stem,  $layer }
        elsif ( length $p && index( $rel, "$p/" ) == 0 ) { push @above, $layer }
    }
    return [ @own, @stem, ( sort { length $b->{key} <=> length $a->{key} } @above ), @site ];
}

# undef when the address admits, else the refusal a caller returns: { ok => 0,
# kind => 'address', error => the ruled sentence }. Not asked outside a web request
# (no REMOTE_ADDR: the users tool, a script) - there is no visitor to limit - and
# there is NO operator bypass: a rule that limits a file to the office limits the
# operator too (the group form of this, an operator group held to one network, is
# slice C's). A refusal is audited once per target per address per hour.
sub address_denial {
    my ( $rel, $origin ) = @_;
    return undef unless defined $ENV{REMOTE_ADDR} && length $ENV{REMOTE_ADDR};
    return undef unless defined $rel              && length $rel;
    my $map = load_acls();
    return undef if $ACLS_FAULT;    # _acl_denied's own store-fault refusal answers
    my $layers = address_chain( $map, $rel );
    return undef unless @$layers;

    require Lazysite::Auth::AddressLists;
    require Lazysite::Auth::AddressAudit;
    no warnings 'once';
    local $Lazysite::Auth::AddressLists::AUTH_DIR = _settings_dir();
    my $address = Lazysite::Auth::AddressLists::client_address();
    for my $l (@$layers) {
        my ( $verdict, $why ) = Lazysite::Auth::AddressLists::decide( $address,
            allow => $l->{allow}, deny => $l->{deny} );
        next if $verdict eq 'allow';
        Lazysite::Auth::AddressAudit::refused(
            lazysite_dir => _lz(),
            target       => '/' . ( _acl_norm($rel) // '' ),
            address      => $address,
            reason       => $why,
            lists        => [ @{ $l->{allow} }, @{ $l->{deny} } ],
            origin       => ( $origin // 'api' ),
        );
        return { ok => 0, kind => 'address', error => 'This page is not available from your address.' };
    }
    return undef;
}

# The per-file allow check with the bypass above; returns a refusal hashref or
# undef if access is allowed. SM979: the bypass is file_rule_bypass, never
# _is_operator - see there.
sub _acl_denied {
    my ( $rel, $mode, $user ) = @_;
    # SM1139: the visitor's address, before the bypass - see address_denial.
    if ( my $by_address = address_denial($rel) ) { return $by_address }
    return undef if file_rule_bypass();
    return undef if _acl_allows( $rel, $mode, $user );
    # SM1024: refused because the store is broken, not because of a rule - the
    # cannot-tell answer, naming the store and the repair (503).
    return {
        ok     => 0,
        kind   => 'cannot-tell',
        store  => 'lazysite/auth/acls.json',
        repair => 'lazysite check --docroot <docroot>',
        error => 'Cannot tell whether you may ' . $mode . ' this file: lazysite/auth/acls.json '
            . 'exists and cannot be read or does not decode. This is a fault on the host, not a '
            . 'rule about this file. Every per-file check is refused until the site operator '
            . 'repairs it; `lazysite check --docroot <docroot>` names the fault.',
    } if $ACLS_FAULT;
    return { ok => 0, error => "You do not have $mode access to this file", kind => 'permission' };
}

1;
