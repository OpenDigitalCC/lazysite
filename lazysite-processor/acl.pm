package main;

# lazysite-processor/acl.pm - the render path's module-free copies of the access
# decisions the Lazysite::Auth tree owns: who may read a file, which groups a
# member holds, and which domains a member's file browser roots at.
#
# HOLDS   _acl_allows_read(), the copy of Auth::Acl's read decision (lint 31),
#         with _acl_map, the rule store read every reader here shares (SM1068),
#         and _acl_entry_for, the longest-match resolver it shares with
#         _acl_is_draft, _acl_governed, _acl_governing_key and _acl_refused,
#         the static file gate; the private-store copies of Lazysite::Private
#         - _private_root and $PRIVATE_ROOT_CACHE, _content_rel, _content_abs,
#         _private_twin, _path_under_content; _groups_grant_cap, ADR 0001's
#         marked copy of Auth::Settings::groups_grant_cap, and _cap_groups, the
#         copy of Auth::Settings::request_cap_groups (SM1135); _group_settings,
#         _group_membership_map and _group_closure, the copies of the compound
#         group resolution; _display_name_for and its memo, the copy of
#         Auth::Settings::display_name_for; the domain-access copy of
#         Auth::DomainAccess - _read_domain_access, _domain_eff, _domain_scopes,
#         _domain_home.
# OWNS    the anonymous path's ACL answer (SM223, SM268, SM287) and its
#         fail-closed store read; draft sections (SM181); the login page never
#         gated by its own rule (SM651); the private store's key derivation
#         (SM286); one group semantics for every reader (SM121, SM268 01-L1);
#         every auth file read as raw octets (ADR 0001).
# CALLS   check_auth, resolve_site_vars, is_auth_surface, _is_engine_asset,
#         not_found, output_page, _security_headers, uri_encode, _path_under,
#         log_event (the script and its parts); realpath and decode_json
#         (imported by the script's `use`, before its parts load).
# READS   $LAZYSITE_DIR and $DOCROOT; SETS $ACL_MAP_CACHE and %ACCESS_REC (the
#         script's, declared `our` there).
#
# A PART OF THE PROCESSOR, NOT A MODULE (SM944 S19). It is package main, required
# by absolute path from lazysite-processor.pl's BEGIN and never through @INC, and
# it loads nothing - ADR 0001 keeps the render path free of the Lazysite:: tree,
# which is why every sub here is a copy.
use strict;
use warnings;

our ( $DOCROOT, $LAZYSITE_DIR, $ACL_MAP_CACHE, %ACCESS_REC, %AUTH_CONTEXT );

# --- ACL, group and domain copies ---

# SM743: the display name for an account, or '' when it has none.
#
# DELIBERATE local copy of Lazysite::Auth::Settings::display_name_for, for the
# same reason _groups_grant_cap below is one: the processor's render path is
# module-free by design (ADR 0001), so it cannot import the shared helper. Keep
# the two in sync - raw-octets read, decode_json, and the same '' on every
# failure.
#
# A FIRST DRAFT CALLED THE SHARED HELPER INSIDE AN eval AND WOULD HAVE BEEN
# INERT. The module is not loaded here, so the call would have died, the eval
# would have swallowed it, and every display name would silently have been ''
# - a feature that ships, appears to work, and does nothing. That is the exact
# shape of SM732's unreachable render and SM743's own dead field, which is a
# poor way to fix a dead field.
#
# MEMOISED ON THE FILE'S IDENTITY, not on a clock, following SM334's settings
# cache and the descriptor cache: a rewrite changes mtime or size, so the key
# misses and the value is re-read. Under the FastCGI pool (SM142) this process
# serves many requests, and reading and decoding user-settings.json on every
# authenticated render is exactly the per-request cost SM663 and SM685 were
# about. A stat is not.
{
    my %_dn_cache;

    sub _display_name_for {
        my ($user) = @_;
        return '' unless defined $user && length $user;

        my $f  = "$LAZYSITE_DIR/auth/user-settings.json";
        my @st = stat $f;
        return '' unless @st;

        my $key = "$f:$st[9]:$st[7]";
        my $all = $_dn_cache{$key};

        unless ($all) {
            # THE SLURP IS SCOPED TO THE READ, for the reason spelled out
            # below in _groups_grant_cap: a `local $/;` left in effect at a
            # sub's top level silently changed how a LATER function read a
            # different file, and cost every nested group its capabilities.
            {
                open my $fh, '<:raw', $f or return '';
                local $/;
                my $raw = <$fh>;
                close $fh;
                $all = eval { decode_json($raw) };
            }
            return '' unless ref $all eq 'HASH';
            %_dn_cache = () if keys %_dn_cache > 4;
            $_dn_cache{$key} = $all;
        }

        return '' unless ref $all->{$user} eq 'HASH';
        my $n = $all->{$user}{display_name};
        return defined $n ? $n : '';
    }
}

# SM095: does any of these groups carry capability $cap (from groups-settings.json)?
# DELIBERATE local copy of Lazysite::Auth::Settings::groups_grant_cap - the
# processor's render path is module-free by design, so it cannot import the
# shared helper. Recorded in docs/adr/0001-capability-resolution.md; keep this
# in sync with the shared implementation (raw-octets read + decode_json).
sub _groups_grant_cap {
    my ( $cap, @groups ) = @_;
    return 0 unless @groups;
    my $f = "$LAZYSITE_DIR/auth/groups-settings.json";
    return 0 unless -f $f;

    # THE SLURP IS SCOPED TO THE READ. `local $/;` at this sub's top level
    # stayed in effect for everything after it - including _group_closure
    # below, whose _group_membership_map reads the groups file with
    # `while (<$fh>)`. In slurp mode that loop takes the WHOLE file as one
    # line, so the map collapsed from 21 groups to 1, the parent table came
    # out empty, and NO nested group ever resolved.
    #
    # What that cost: a capability held by a group through nesting - which is
    # how the shipped groups are arranged, ch-ui containing site-admins and
    # the rest - was never granted. An account in site-admins was told
    # "Manager access not permitted". It fails CLOSED, so it is a lockout
    # rather than a leak, and it is invisible to any test whose user is in a
    # group that holds the capability DIRECTLY.
    my $gs;
    {
        open my $fh, '<:raw', $f or return 0;
        local $/;
        $gs = eval { JSON::PP::decode_json(<$fh>) } || {};
        close $fh;
    }
    for my $g ( _group_closure(@groups) ) {    # SM121: compound-expanded
        return 1 if ref $gs->{$g} eq 'HASH' && $gs->{$g}{$cap};
    }
    return 0;
}

# SM1135 (SM1128 phase 1, P1-6; ruled R1): WHICH OF THE REQUEST'S GROUPS MAY GRANT
# A CAPABILITY. DELIBERATE local copy of Auth::Settings::request_cap_groups (ADR
# 0001: the render path loads no Lazysite:: module up front). Groups a trusted
# proxy named give page and file access by name; they grant a capability only if
# the operator marked the group `directory_grants`. A cookie or direct identity is
# the account's own and passes whole. The caller hands the groups it holds; the
# SOURCE comes from the one identity reader, so the answer does not depend on
# which caller asks.
sub _cap_groups {
    my (@groups) = @_;
    return @groups unless @groups;
    return @groups unless ( _request_identity()->{source} // '' ) eq 'proxy';
    my $gs = _group_settings();
    return grep { ref $gs->{$_} eq 'HASH' && $gs->{$_}{directory_grants} } @groups;
}

# SM223: which ACL entry governs $rel? Exact path first, then the LONGEST
# matching folder prefix, so a tighter rule on a sub-folder beats a broader one
# above it. Folder scope is an entry in the same store rather than a separate
# prefix rule in lazysite.conf - one place to look, and one place to be wrong.
sub _acl_entry_for {
    my ( $map, $rel, $mode ) = @_;
    $mode //= '';
    $rel =~ s{\A/+}{};

    # SM268 H10: an entry with no list for the mode we are deciding is NOT a
    # tighter rule - it is NO rule, and it must not win the longest match.
    #
    # "Longest match wins" is documented as "a tighter rule on a sub-folder beats
    # a broader one above it". An owner-only entry says nothing about reading, so
    # letting it beat an enclosing folder's `read` list turned the folder gate
    # off for that one file. The operator action that produced it is DUPLICATE in
    # the file manager: action_copy writes `{ owner => $user }` for the new file,
    # so copying a file inside a protected section republished it to the world -
    # no warning, no log line, and performed by someone who need not hold any
    # permission-changing capability.
    #
    # So for a mode decision, only entries carrying a non-empty list for that
    # mode are candidates. With no mode every entry counts.
    #
    # SM1068 (ruled 2026-10-13, "Read/draft only"): 'see' is the mode for "does
    # a rule change what a viewer sees here?" - an entry carrying a read list
    # or `draft`. It is what the cache check, the registries and an include ask.
    # A write list says who may CHANGE a page and nothing about who may see it,
    # so asking with no mode made every page under a write-only rule per-viewer:
    # never cached, no-store, and out of every registry.
    #
    # SM981: the DRAFT check is a mode of its own - only an entry carrying
    # `draft` decides it. It asked with no mode, so the nearest entry of ANY kind
    # won, and a file's owner-only rule (every copy, and a moved file's re-keyed
    # rule) hid its folder's draft flag: a page moved into a draft folder with no
    # read list was served to anonymous visitors. The H10 reasoning above, for
    # the flag it had not yet been applied to.
    my $governs = sub {
        my ($e) = @_;
        return 0 unless ref $e eq 'HASH';
        return 1 unless length $mode;
        return ( $e->{draft} ? 1 : 0 ) if $mode eq 'draft';
        return ( $e->{draft} || ( ref $e->{read} eq 'ARRAY' && @{ $e->{read} } ) ) ? 1 : 0
            if $mode eq 'see';    # SM1068
        return ( ref $e->{$mode} eq 'ARRAY' && @{ $e->{$mode} } ) ? 1 : 0;
    };

    return $map->{$rel} if $governs->( $map->{$rel} );

    # SM268 H14: a folder entry covers the section's OWN landing page.
    #
    # `private.md` renders at /private and `private/index.md` at /private/, so a
    # gate on the folder `private` left its front door open: /private served its
    # body while /private/ bounced to login. The page that introduces a held-back
    # section is the last one that should be public.
    if ( $rel =~ m{\A(.+)\.(?:md|url|html)\z} ) {
        my $stem = $1;
        return $map->{$stem} if $governs->( $map->{$stem} );
    }

    # SM1069: THE ANCESTORS ARE LOOKED UP, NOT FOUND BY A WALK. A folder key
    # governs $rel when, with its leading and trailing slashes taken off, it is
    # a prefix of $rel followed by `/` - so the candidates are exactly the
    # prefixes of $rel ending before each `/`, and the longest one that governs
    # wins. The walk tested every key in the store for each path; a registry
    # rebuild asks for every page, which made it pages x rules. The index maps
    # each key's normalised spelling to the keys spelled that way, built once
    # per decoded store.
    my $idx = _acl_prefix_index($map);
    my $i   = length $rel;
    while ( ( $i = rindex( $rel, '/', $i - 1 ) ) > 0 ) {
        my $p = substr( $rel, 0, $i );
        next if $p =~ m{/\z};    # `a//b`: `a/` is no key's normalised spelling
        for my $k ( @{ $idx->{$p} || [] } ) {
            return $map->{$k} if $governs->( $map->{$k} );
        }
    }

    # SM287: the SITE-WIDE rule, and it is the WEAKEST - checked only when
    # nothing more specific governs, so a public carve-out inside a private site
    # stays expressible (which is the common shape: everything private except
    # the landing page).
    #
    # Before this, a root entry did nothing under any spelling. Not by an
    # oversight in one branch: the loop above skips a zero-length prefix, and
    # even without that guard `index($rel, "$p/")` can never match an empty
    # prefix because the leading slash has already been stripped from $rel. So
    # there was NO way to say "this whole site is private" - auth_default governs
    # pages and deliberately does not reach statics, and enumerating top-level
    # folders fails OPEN as content grows, since a file added at the root next
    # month is public with nothing to say so.
    #
    # '/' is what the writer stores. '' and '.' are accepted too: a hand-edited
    # store is a real interface here and all three plainly mean the same thing.
    # Glob spellings are NOT accepted - the store has no matching language, and
    # audit_site's acl_keys_matching_nothing surfaces a key that governs nothing.
    for my $rk ( '/', '', '.' ) {
        return $map->{$rk} if $governs->( $map->{$rk} );
    }
    return;
}

# SM1069: a store's folder keys by their normalised spelling (leading and
# trailing slashes off; '' left out, the site-wide rule being checked on its
# own), each to its keys in sorted order.
#
# Kept only for the store _acl_map handed out - the one map no reader writes to,
# the same until the store changes - in one slot holding that map, so its
# address cannot be reused by the next while the index still names it. Any
# other map (a caller's own, which it may change between calls) is indexed
# afresh each time: the cost of the walk this replaces, and never stale.
{
    my ( $_idx_map, $_idx );

    sub _acl_prefix_index {
        my ($map) = @_;
        my $store = ref $ACL_MAP_CACHE eq 'HASH' && $map == $ACL_MAP_CACHE;
        return $_idx if $store && defined $_idx_map && $_idx_map == $map;
        my %idx;
        for my $k ( sort keys %$map ) {
            ( my $p = $k ) =~ s{\A/+}{};
            $p =~ s{/+\z}{};
            push @{ $idx{$p} }, $k if length $p;
        }
        ( $_idx_map, $_idx ) = ( $map, \%idx ) if $store;
        return \%idx;
    }
}

# SM223: may this identity READ $rel on the anonymous/public path?
#
# DELIBERATE local copy of Lazysite::Auth::Acl::_acl_allows - the render path is
# module-free by design (ADR 0001), and Auth::Acl pulls in JSON::PP, File::Path
# and Auth::Settings. Keep the semantics in sync with the shared implementation;
# t/lint/31 pins them.
#
# The semantics are deliberately UNCHANGED from the authoring channels, because
# this is the same question asked by a different caller:
#
#   * no entry            -> allowed. A static file nobody has said anything
#                            about is served, exactly as before. auth_default
#                            does NOT reach static files; protecting one is an
#                            explicit act.
#   * owner matches       -> allowed.
#   * no read list        -> allowed. An entry carrying only an owner does not
#                            restrict reading, here or in the manager.
#   * read list           -> the user or one of their groups must appear.
#
# An anonymous request has no user and no groups, so a read list refuses it -
# which is the point.
#
# NOTE the caller must use THIS, never Auth::Acl::_acl_denied: that routes
# through _is_operator, which returns 1 on a site where no group grants manager
# access. On an anonymous request that would treat the public as an operator and
# bypass the ACL entirely, on exactly the sites least equipped to notice.
# SM286: the private content store, resolved module-free.
#
# DELIBERATE local copy of Lazysite::Private - the render path loads no Lazysite
# modules (ADR 0001), exactly as _acl_allows_read copies Auth::Acl. t/lint/36
# pins the pair.
#
# Nothing moves content here yet, and before this the private tree was simply
# never consulted - a path there was not found, so it 404'd and nothing leaked.
#
# THE TRAP, MEASURED. Resolution and key derivation must change TOGETHER. Every
# ACL predicate below derives its docroot-relative key with `s{^$DOCROOT/}{}`,
# which FAILS for a path in the private tree, and each returns 0 on failure -
# meaning "not governed", "not draft", "not refused". Add _content_abs alone,
# leaving those three as they were, and a gated file in the private store is
# served to anonymous visitors, to the wrong user, and out of a draft section.
# Verified by doing exactly that and watching the test go red.
#
# So this is not preparation that could be split further. Anyone continuing the
# wiring on the other surfaces should assume the same shape: wherever a surface
# turns an absolute path back into a key, resolving the new tree without fixing
# the derivation opens a hole rather than leaving one closed.
our $PRIVATE_ROOT_CACHE;

sub _private_root {
    return $PRIVATE_ROOT_CACHE if defined $PRIVATE_ROOT_CACHE;
    my $d = $DOCROOT // '';
    $d =~ s{/+\z}{};
    return $PRIVATE_ROOT_CACHE = '' unless length $d;

    # Named for the docroot, not a fixed name in the parent - or two docroots
    # sharing a parent share one store and each resolves the other's protected
    # content by path. Mirrors Lazysite::Private::private_root; t/lint pins the
    # pair (ADR 0001 keeps this copy module-free, which makes drift the risk).
    my $leaf = $d;
    $leaf =~ s{\A.*/}{};         # basename, without File::Basename
    my $parent = $d;
    $parent =~ s{/[^/]*\z}{};    # dirname, likewise
    return $PRIVATE_ROOT_CACHE = "$parent/$leaf-lazysite-private";
}

# The docroot-relative ACL key for an absolute path in EITHER tree. undef when
# the path is in neither, which every caller must treat as "not content".
sub _content_rel {
    my ($abs) = @_;
    return undef unless defined $abs && length $abs;
    my $rel = $abs;
    return $rel if $rel =~ s{\A\Q$DOCROOT\E/}{};
    my $priv = _private_root();
    return $rel if length $priv && $rel =~ s{\A\Q$priv\E/}{};
    return undef;
}

# Where a docroot-anchored path actually lives. PRIVATE WINS when both exist -
# the same fail-safe direction Lazysite::Private takes, because a stray public
# copy is already reachable by the front end and serving it from here too would
# hide the fault.
sub _content_abs {
    my ($abs) = @_;
    return $abs unless defined $abs;
    my $rel = $abs;
    if ( $rel =~ s{\A\Q$DOCROOT\E/}{} ) {
        my $priv = _private_root();
        return "$priv/$rel" if length $priv && -e "$priv/$rel";
    }
    return $abs;
}

# The private twin of a docroot path, whether or not it exists. Used for files
# that must FOLLOW their source into the store rather than be looked up - the
# page cache above all: a gated page whose .html render lands in the docroot has
# republished the very content the gate was protecting, in a file the front end
# serves without asking anything.
sub _private_twin {
    my ($abs) = @_;
    return $abs unless defined $abs;
    my $priv = _private_root();
    return $abs unless length $priv;
    return $priv if $abs eq $DOCROOT;    # the store mirrors the docroot itself
    my $rel = $abs;
    return $abs unless $rel =~ s{\A\Q$DOCROOT\E/}{};
    return "$priv/$rel";
}

# Confinement for a resolved content path: inside the domain's content root, OR
# inside that root's twin in the private store.
#
# NOT "anywhere in the private store". The check this widens exists so a symlink
# in one domain's tree cannot serve a sibling domain's files (SM151 spec S1), and
# the store mirrors the docroot's shape - so the twin of $croot is the exactly
# equivalent boundary. Accepting the whole store would hand every domain access
# to every other domain's private content, which is a bigger hole than the one
# the private store closes.
sub _path_under_content {
    my ( $real, $croot ) = @_;
    return 1 if _path_under( $real, $croot );
    my $twin = _private_twin($croot);
    return 0 if !defined $twin || $twin eq $croot;
    return _path_under( $real, $twin ) ? 1 : 0;
}

# SM1068: THE RULE STORE, decoded once per CHANGE rather than once per reader.
#
# Returns the decoded map, or 0 for a store that exists and will not open or
# decode (SM268 H12, SM1024: the caller fails closed on 0). Every reader in this
# part asks here, so a request decodes at most once - and before this,
# _acl_is_draft decoded on every call of its own, which a registry rebuild makes
# once per page.
#
# Two layers. $ACL_MAP_CACHE is the request's answer (SM268 H13), cleared by
# reset_request_state (SM973). Under it, a process-wide copy keyed on the
# file's identity - path, mtime, size, inode and ctime - the key
# Lazysite::Auth::Acl::load_acls uses, plus the two that make a chmod or a
# rename-over a new key. A persistent worker therefore decodes once per change;
# a one-shot CGI still decodes once, since its memory ends with the request.
#
# Kept only when the file is more than a second old, as load_acls does (it asks
# of mtime; this asks of ctime, which a backdated write cannot hold back): two
# writes inside one second can leave mtime, size and ctime all equal, and the
# second must not be answered from the first. The copy is shared and read-only:
# no reader here writes to the map. A failure to DECODE is kept as a
# failure (closed), never as {}; a failure to OPEN is never kept, since what
# changes it (a permission) may not change the key.
{
    my %_acl_store;

    sub _acl_map {
        my ($rel) = @_;
        return $ACL_MAP_CACHE if defined $ACL_MAP_CACHE;
        my $f   = "$LAZYSITE_DIR/auth/acls.json";
        my @st  = stat $f;
        my $key = @st         ? join( ':', $f, @st[ 9, 7, 1, 10 ] ) : '';
        my $got = length $key ? $_acl_store{$key}                   : undef;

        unless ( defined $got ) {
            my $raw = do {
                if ( open my $fh, '<:raw', $f ) {
                    local $/;
                    my $c = <$fh>;
                    close $fh;
                    $c;
                }
                else { undef }
            };
            unless ( defined $raw ) {
                log_event( 'ERROR', $rel // '-', 'ACL store unreadable - refusing (fail closed)' );
                return $ACL_MAP_CACHE = 0;
            }
            my $map = eval { JSON::PP::decode_json($raw) };
            $got = ref $map eq 'HASH' ? $map : 0;
            if ( length $key && $st[10] < time() - 1 ) {
                %_acl_store = () if keys %_acl_store > 4;
                $_acl_store{$key} = $got;
            }
        }
        log_event( 'ERROR', $rel // '-',
            'ACL store unparseable - refusing (fail closed). Fix '
                . 'lazysite/auth/acls.json; every protected path is denied until you do.' )
            unless ref $got eq 'HASH';
        return $ACL_MAP_CACHE = $got;
    }
}

sub _acl_allows_read {
    my ( $rel, $user, @groups ) = @_;
    my $f = "$LAZYSITE_DIR/auth/acls.json";
    return 1 unless -f $f;

    # SM268 H12: a store that EXISTS but cannot be read or parsed fails CLOSED.
    #
    # It used to fail open, silently: no WARN, no access-log flag, and every
    # protected file served to anyone. Hand-written JSON is the only interface
    # for a folder rule (SM181), so a stray comma is a realistic way to reach
    # this - and the failure was indistinguishable from having no rules at all.
    #
    # Closed is the right direction and it is recoverable: the site refuses,
    # which is loud, and the manager is unaffected (it reads through Auth::Acl),
    # so an operator can still get in and fix the file. Open is not recoverable -
    # the disclosure has already happened by the time anyone notices.
    # Parsed at most once per request. SM268 H13 made this a hot path: a scan
    # filters up to 200 pages through it, and re-reading and re-decoding the
    # store per page would turn one render into 200 opens. A failed load is
    # cached as a failure, so it still fails closed and still logs once.
    # SM1068: through _acl_map, which also keeps it across requests.
    my $map = _acl_map($rel);
    return 0 unless ref $map eq 'HASH';
    return 1 unless keys %$map;

    my $a = _acl_entry_for( $map, $rel, 'read' );
    return 1 unless ref $a eq 'HASH';
    return 1 if defined $a->{owner} && length $user && $a->{owner} eq $user;

    my $list = $a->{read};
    return 1 unless ref $list eq 'ARRAY' && @$list;

    # SM268 01-L1: one group semantics, not three. This compared the raw
    # X-Remote-Groups list exactly, while check_auth's `groups:` comparison
    # lowercases both sides and _groups_grant_cap expands compound groups
    # through the closure - so `Editors` was refused where `editors` was
    # allowed, and membership of a group NESTED in the granted one did not
    # count. It failed closed, so it was a correctness defect rather than an
    # exposure, but a sysop meeting it reads it as "the ACL is broken" and
    # the obvious repair is to widen the rule.
    my %grp = map { lc($_) => 1 } _group_closure(@groups);
    for my $e (@$list) {
        next unless defined $e && length $e;
        if ( $e =~ /\A\@(.+)\z/ ) {
            my $g = lc $1;    # capture immediately - any later match clobbers $1
            return 1 if $grp{$g};
        }
        elsif ( length $user && $e eq $user ) {
            return 1;
        }
    }
    return 0;
}

# SM223: is an ACL entry governing this file at all?
#
# Separate from the allow decision because the ALLOWED case still matters: if the
# answer depended on who asked, the response must not be stored by a shared
# cache, the same rule protected pages already follow. A file with no entry is
# ordinary public content and stays cacheable.
# SM181: is this path inside a DRAFT section?
#
# Draft is an attribute of a protected entry, not a separate mechanism:
#
#   { "upcoming": { "read": ["@editors"], "draft": true } }
#
# It changes two things and nothing else:
#
#   * the refusal becomes a 404 rather than a bounce to login. A section held
#     back before launch should not answer at guessable URLs - a 403 or a login
#     form confirms that /upcoming/pricing exists, which is the thing being held
#     back. This filing's own words: "don't even reveal the URLs".
#   * it is absent from the registries and from search, always - for everyone,
#     regardless of who triggered the generation. A sitemap is written once and
#     served to the public, so a draft page listed in it is published no matter
#     what the page itself answers.
#
# An ANONYMOUS request is never allowed into a draft section, even when the entry
# carries no read list. That differs from the ordinary rule (no list = allowed)
# and it has to: a draft with no list would otherwise be public, which is the
# opposite of what the word means. With no list, any signed-in user may preview;
# with one, the list decides.
sub _acl_is_draft {
    my ($abs) = @_;
    my $f = "$LAZYSITE_DIR/auth/acls.json";
    return 0 unless -f $f;
    my $real = realpath($abs);
    return 0 unless defined $real;
    my $rel = _content_rel($real);
    return 0 unless defined $rel;

    # SM1068: the shared read. It decoded the store itself on every call, so a
    # registry rebuild decoded it once per page. A store that will not load
    # answers "not draft", as it did: the read check that follows refuses.
    my $map = _acl_map($rel);
    return 0 unless ref $map eq 'HASH';
    my $a = _acl_entry_for( $map, $rel, 'draft' ); # SM981: an entry carrying draft decides
    return ( ref $a eq 'HASH' && $a->{draft} ) ? 1 : 0;
}

# SM1139 (slice B of SM1134): A PAGE, A FILE OR A FOLDER LIMITED BY THE VISITOR'S
# ADDRESS. Three places can name address lists for a path, and the path is served
# only when EVERY layer that names any admits the visitor:
#
#   the page's front matter    `addresses: [office]`  `addresses_deny: [blocked]`
#   the path's own rule        acls.json entry for the file (or its page stem)
#   each enclosing folder rule acls.json entries for every ancestor, and the
#                              site-wide rule
#
# EACH LAYER IS DECIDED ON ITS OWN, by Lazysite::Auth::AddressLists::decide: the
# address must be in one of THAT layer's allow lists and in none of its deny lists.
# So a page allowing [office] inside a folder allowing [office, vpn] is served to
# the office only, and a folder's allow list cannot be widened by a page inside it:
# AND across layers, OR within a layer, and any deny wins (SM1134 ruling).
#
# NOT the longest-match rule the read lists use (_acl_entry_for). A read rule
# names who may read and a tighter inner rule may re-state it; an address rule is a
# restriction, and the reason a sub-folder carries one is to narrow what its parent
# allows. Letting the inner rule replace the outer would let a folder be opened to
# the world by a rule written inside it, which is the opposite of a limit.
#
# THE RENDER PATH IS MODULE-FREE (ADR 0001), so the decision is not copied here: the
# module is loaded on first use by _lazy_lib, exactly as Auth::Identity is for the
# page gate (SM1131), and only when a layer names a list - a site with no address
# rule never loads it. The lazy load is the established pattern, and a pinned copy
# of the decision would be a second answer to "is this address in that list" where
# SM1138 made one.

# The refusal sentence, ruled 2026-10-17 (SM1134, question 5). It does not name the
# list. Lazysite::Auth::Acl::address_denial carries the same words; t/unit/processor/140
# holds the two together.
sub _address_refusal_sentence { return 'This page is not available from your address.' }

# The acls.json entries, nearest first, that name an address list for $rel: its own
# key, its page stem's (a folder's rule covers the section's landing page, SM268
# H14), every ancestor folder's, then the site-wide rule. Returns [ { key, allow,
# deny } ]. An entry naming no list is not a layer.
sub _address_chain {
    my ( $map, $rel ) = @_;
    return [] unless ref $map eq 'HASH';
    $rel =~ s{\A/+}{};
    my ( @out, %seen );
    my $take = sub {
        my ($k) = @_;
        return unless defined $k && !$seen{$k}++;
        my $e = $map->{$k};
        return unless ref $e eq 'HASH';
        my $allow = ref $e->{addresses} eq 'ARRAY' ? [ grep { defined && !ref } @{ $e->{addresses} } ] : [];
        my $deny = ref $e->{addresses_deny} eq 'ARRAY' ? [ grep { defined && !ref } @{ $e->{addresses_deny} } ] : [];
        push @out, { key => $k, allow => $allow, deny => $deny } if @$allow || @$deny;
    };
    $take->($rel) if exists $map->{$rel};
    $take->($1)   if $rel =~ m{\A(.+)\.(?:md|url|html)\z} && exists $map->{$1};
    my $idx = _acl_prefix_index($map);
    my $i   = length $rel;
    while ( ( $i = rindex( $rel, '/', $i - 1 ) ) > 0 ) {
        my $p = substr( $rel, 0, $i );
        next if $p =~ m{/\z};
        $take->($_) for @{ $idx->{$p} || [] };
    }
    $take->($_) for '/', '', '.';
    return \@out;
}

# Every layer that limits $abs by address: the page's own front matter (a .md page
# only), then its acls.json chain. [] when nothing limits it - the common case, and
# the cheap one: no store and no front-matter list is two file tests.
sub _address_layers_for {
    my ($abs) = @_;
    my @layers;
    if ( $abs =~ /\.md\z/ ) {
        my $m = peek_auth($abs);
        push @layers, { key => "page:$abs", allow => $m->{addresses}, deny => $m->{addresses_deny} }
            if @{ $m->{addresses} || [] } || @{ $m->{addresses_deny} || [] };
    }
    my $f = "$LAZYSITE_DIR/auth/acls.json";
    if ( -f $f ) {
        my $real = realpath($abs);
        my $rel  = defined $real ? _content_rel($real) : undef;
        # A store that will not load is refused to everyone by _acl_refused's own
        # read check; there is no chain to read from it.
        if ( defined $rel ) {
            my $map = _acl_map($rel);
            push @layers, @{ _address_chain( $map, $rel ) } if ref $map eq 'HASH';
        }
    }
    return \@layers;
}

# 1 if it has written a refusal (the caller stops), 0 to carry on. Asked FIRST by
# _acl_refused, before the who-may-read check, for two reasons: it needs no
# identity, so an address outside the rule is refused without a sign-in that could
# not help it (a login bounce would send a visitor to a form that cannot admit them);
# and it must not be skipped by anything a page can declare about itself, as a
# section gate must not be overridable by `auth: none` (SM181). BOTH rules must
# allow - an address rule narrows who may read, it never widens it - so passing here
# only hands the request to the existing checks.
#
# A DRAFT section answers 404 instead, as _acl_refused does for its own refusals: a
# 403 naming "your address" would confirm the URL exists, the thing SM181 holds back.
sub _address_refused {
    my ( $abs, $uri ) = @_;
    my $layers = _address_layers_for($abs);
    return 0 unless @$layers;

    # SM651: the way in is never gated by the thing it is the way in to.
    return 0 if is_auth_surface($uri) || _is_engine_asset($uri);

    _lazy_lib('Lazysite::Auth::AddressLists');
    _lazy_lib('Lazysite::Auth::AddressAudit');
    {
        no warnings 'once';
        $Lazysite::Auth::AddressLists::AUTH_DIR = "$LAZYSITE_DIR/auth";
    }
    my $address = Lazysite::Auth::AddressLists::client_address();
    for my $l (@$layers) {
        my ( $verdict, $why ) = Lazysite::Auth::AddressLists::decide( $address,
            allow => $l->{allow}, deny => $l->{deny} );
        next if $verdict eq 'allow';

        log_event( 'WARN', $uri, 'refused by address', reason => $why );
        Lazysite::Auth::AddressAudit::refused(
            lazysite_dir => $LAZYSITE_DIR,
            target       => $uri,
            address      => $address,
            reason       => $why,
            lists        => [ @{ $l->{allow} }, @{ $l->{deny} } ],
            origin       => 'web',
        );
        $ACCESS_REC{ar} = 1;
        if ( _acl_is_draft($abs) ) {
            not_found($uri);
            return 1;
        }
        %AUTH_CONTEXT = ( authenticated => 0, auth_denied_reason => 'address' );
        serve_403( { forbidden => 1, auth_denied_reason => 'address' } );
        return 1;
    }
    return 0;
}

sub _acl_governed {
    my ($abs) = @_;
    # SM1139: a path limited by address varies by visitor, so it is governed: no
    # shared cache either way, no-store on the response, out of the registries.
    return 1 if @{ _address_layers_for($abs) };
    my $f = "$LAZYSITE_DIR/auth/acls.json";
    return 0 unless -f $f;
    my $real = realpath($abs);
    return 0 unless defined $real;
    my $rel = _content_rel($real);
    return 0 unless defined $rel;

    # Shares _acl_allows_read's parse (SM268 H13, SM1068). A store that failed
    # to load counts as governing everything: _acl_allows_read is refusing every
    # path, and the callers want that answer - no-store on the response, and out
    # of the registries.
    #
    # SM1024: a store that opens and does not decode is a FAILED load, as one
    # that will not open is - governs everything, and cached as a failure. It
    # decoded `|| {}` and cached the empty map, so the _acl_allows_read that
    # followed in the same request found "no rules" and allowed every path, and
    # the registries listed every governed page.
    my $map = _acl_map($rel);
    return 1 unless ref $map eq 'HASH';

    # SM1068 (ruled 2026-10-13, "Read/draft only"): governed means a rule that
    # changes what a viewer SEES - a read list or a draft flag. A write-only
    # rule leaves the page the same for every viewer: cacheable, and listed.
    return ref( _acl_entry_for( $map, $rel, 'see' ) ) eq 'HASH' ? 1 : 0;
}

# SM898: WHICH entry governs a path - its key - or undef when none does.
#
# `::: include` needs to know not whether the partial is governed but whether
# the including page is governed BY THE SAME RULE, and _acl_entry_for returns
# the entry without its key. The key is recovered by identity against the map
# rather than by repeating the longest-match logic here: two copies of "which
# rule wins" is how the two halves of a rule come to disagree (SM268 H10 was
# one such copy). Same store, same per-request parse, same failed-load answer
# as _acl_governed: a store that will not load governs everything, and here
# that means every path reports the same sentinel key and no include of
# governed content is refused for being outside its section - the failed load
# has already refused every page, which is the louder answer.
sub _acl_governing_key {
    my ($abs) = @_;
    my $f = "$LAZYSITE_DIR/auth/acls.json";
    # SM1139: no store still leaves a page's own front-matter address lists.
    unless ( -f $f ) {
        my @own = map { $_->{key} } @{ _address_layers_for($abs) };
        return @own ? join( '+', @own ) : undef;
    }
    my $real = realpath($abs);
    return undef unless defined $real;
    my $rel = _content_rel($real);
    return undef unless defined $rel;

    # SM1024: undecodable is a failed load, as in _acl_governed above.
    my $map = _acl_map($rel);
    return '*' unless ref $map eq 'HASH';

    # SM1068: the rule that decides who SEES the path, as _acl_governed asks. A
    # write-only rule decides no audience, so a partial under one is public
    # content, and a page under one is "governed by nothing" for this check.
    my $entry = _acl_entry_for( $map, $rel, 'see' );
    my $key;
    if ( ref $entry eq 'HASH' ) {
        for my $k ( keys %$map ) {
            if ( ref $map->{$k} eq 'HASH' && $map->{$k} == $entry ) { $key = $k; last }
        }
    }

    # SM1139: AN ADDRESS RULE IS AN AUDIENCE TOO. A partial limited to the office
    # included by a public page would put the office's text in front of everyone,
    # so the including page must sit under the same address rules as the partial.
    # The key is the read rule's key and then each address layer's, so a path with
    # no address rule answers exactly as it did.
    my @addr = map { $_->{key} } @{ _address_layers_for($abs) };
    return $key unless @addr;
    return join( '+', ( defined $key ? $key : () ), @addr );
}

# SM223: gate a SOURCE-LESS static file (no .md/.url behind it) on the ACL.
#
# Returns true when it has already written a response and the caller must stop.
# A page with a Markdown source is gated by check_auth as before and never
# reaches here.
#
# Anonymous and refused bounces to the login page, the way a protected page
# does, so a person following a link to a private PDF gets somewhere useful.
# Authenticated and refused gets 403, because logging in again will not help.
sub _acl_refused {
    my ( $abs, $uri ) = @_;

    # SM1139: the visitor's address first (see _address_refused).
    return 1 if _address_refused( $abs, $uri );

    my $f = "$LAZYSITE_DIR/auth/acls.json";
    return 0 unless -f $f;    # no store, no cost

    # SM651: THE WAY IN IS NEVER GATED BY THE THING IT IS THE WAY IN TO.
    #
    # A rule at `/` governs every path, including the login page. An anonymous
    # visitor is redirected to /login; /login is anonymous; it is refused and
    # redirected to itself. Measured: four redirects deep and still 302. The
    # chrome stylesheet went with it, so even a reachable login page would have
    # rendered unstyled.
    #
    # WORSE THAN AN ORDINARY MISCONFIGURATION, because signing in is the only
    # way to get an interactive session to undo it: a site protected this way
    # FROM THE MANAGER UI takes its operator's own access with it. The test
    # instance recovered only because the rule was set over a partner token,
    # which still reaches acl-remove - a route a browser user does not have.
    #
    # check_auth has carried exactly this carve-out for auth_default since it
    # was written; the ACL path never had it. The same question asked by a
    # different caller should not get a different answer, so it is asked once
    # here, ahead of the store, and covers all four callers of this sub.
    #
    # NOT a rule about the path `/` specifically: a rule at any depth that
    # governs the login page has the same effect, and a sysop who names
    # /login explicitly has still not asked to be locked out.
    # SM651: is_auth_surface() already answers "is this the way in", follows
    # auth_redirect and covers logout; it has been the cache-protection
    # predicate since SM071. Reusing it rather than writing a second one is the
    # point - two predicates for one question is how the two halves of a rule
    # start disagreeing, which is the defect SM654 filed against a hand-kept
    # copy of the same fact. The engine's own chrome is added because a login
    # page that renders unstyled is not a usable way in.
    return 0 if is_auth_surface($uri) || _is_engine_asset($uri);

    my $real = realpath($abs);
    return 0 unless defined $real;
    my $rel = _content_rel($real);
    return 0 unless defined $rel;

    my %sv = resolve_site_vars();
    # auth => 'none' asks check_auth for the IDENTITY without enforcement, so
    # auth_default is not consulted - static files are governed by the ACL alone.
    my $id     = check_auth( $uri, { auth => 'none' }, \%sv );
    my @groups = @{ $id->{auth_groups} // [] };
    my $user   = $id->{auth_user} // '';

    # SM181: a draft section is not published, so an anonymous request is refused
    # even when the entry carries no read list - and refused as a 404, which
    # reveals nothing about what is being held back.
    my $draft = _acl_is_draft($abs);
    if ( $draft && !$id->{authenticated} ) {
        log_event( 'INFO', $uri, 'draft section hidden from the public' );
        not_found($uri);
        return 1;
    }

    return 0 if _acl_allows_read( $rel, $user, @groups );

    # A signed-in user outside a DRAFT section's list also gets 404, not 403:
    # the section's existence is the thing being withheld, and a 403 to an
    # authenticated non-editor discloses it just as effectively as one to the
    # public.
    if ($draft) {
        log_event( 'WARN', $uri, 'draft section refused', user => $user );
        not_found($uri);
        return 1;
    }

    if ( $id->{authenticated} ) {
        log_event( 'WARN', $uri, 'static refused by ACL', user => $user );
        $ACCESS_REC{s} //= 403;
        $ACCESS_REC{ar} = 1;
        # SM381: through output_page. This is an ACCESS REFUSAL on a static,
        # which makes it one of the responses most worth carrying the header
        # set rather than least.
        return output_page(
            "<!DOCTYPE html><html><body><h1>Forbidden</h1>"
                . "<p>You do not have access to this file.</p></body></html>\n",
            'text/html; charset=utf-8', undef, 1, '403 Forbidden' );
    }

    log_event( 'WARN', $uri, 'static refused by ACL', user => '-' );
    $ACCESS_REC{s} //= 302;
    $ACCESS_REC{ar} = 1;
    my $redirect_path = $sv{auth_redirect} || '/login';
    my $next          = uri_encode($uri);
    binmode( STDOUT, ':utf8' );
    print "Status: 302 Found\r\n";
    print "$_\r\n" for _security_headers();    # SM381
    print "Cache-Control: no-store\r\n";
    # SM353: state the type. With none, the response carried the CGI's own
    # (text/x-perl) - wrong on every gated request on every site, and it
    # advertised the implementation language on a security boundary for nothing.
    print "Content-Type: text/html; charset=utf-8\r\n";
    print "Location: $redirect_path?next=$next\r\n\r\n";
    return 1;
}

# Module-free raw-octets read of groups-settings.json, keeping the render path
# free of Lazysite modules (ADR 0001). The store carries each group's
# capabilities and its nesting, which _group_closure and _groups_grant_cap
# resolve.
#
# SM279: it also USED to carry a `dav_scope` confinement, read here by
# _group_scopes / _group_home_domain. Those were removed - SM165 moved
# confinement to the domain-owned model in 0.7.26 and the two copies here were
# dead code from that day, so the file browser roots from _domain_scopes /
# _domain_home instead.
sub _group_settings {
    my $f = "$LAZYSITE_DIR/auth/groups-settings.json";
    return {} unless -f $f;
    open my $fh, '<:raw', $f or return {};
    local $/;
    my $gs = eval { JSON::PP::decode_json(<$fh>) } || {};
    close $fh;
    return ref $gs eq 'HASH' ? $gs : {};
}

# SM121: compound groups - a group may list another GROUP as a member, so its
# members inherit the parent's caps/scope. Module-free copies of
# Auth::Settings::_group_closure and _groups_membership, kept in step, so the
# render path expands the request's groups the same way the resolver does
# (ADR 0001). Without this a member of a compound group would get its inherited
# caps over the API/dav but be denied at the render path (e.g. manager access).
sub _group_membership_map {
    local $_;    # SM420: while(<>) assigns the GLOBAL $_
    my $f = "$LAZYSITE_DIR/auth/groups";
    my %g;
    return %g unless -f $f;
    open my $fh, '<:utf8', $f or return %g;
    while (<$fh>) {
        chomp;
        s/^\s+|\s+$//g;
        next if /^#/ || !length;
        my ( $grp, $mem ) = split /:\s*/, $_, 2;
        next unless defined $mem;
        $g{$grp} = [ map { s/^\s+|\s+$//gr } split /,/, $mem ];
    }
    close $fh;
    return %g;
}

sub _group_closure {
    my (@seed) = @_;
    return @seed unless @seed;
    my %membership = _group_membership_map();
    my $gs         = _group_settings();
    my %is_group   = map { $_ => 1 } ( keys %membership, keys %{$gs} );
    my %parent;
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

# SM165: the module-free render-path copy of the DOMAIN-access scope resolution
# (a local copy of Auth::DomainAccess, kept in step, ADR 0001). Roots the file
# browser at the domains a user's groups allow (narrowed by any lock). The
# AUTHORITATIVE confinement - including the sub-user ceiling - is applied
# SERVER-SIDE by the manager API / WebDAV via resolve_user_scopes; this render
# copy is only the UI rooting hint, so it omits the ceiling (a sub-user still
# cannot ACT outside its ceiling).
sub _read_domain_access {
    my $f   = "$LAZYSITE_DIR/lazysite.conf";
    my %dom = ( '' => { content_root => '', allowed_groups => [], locked_users => [] } );
    open my $fh, '<:utf8', $f or return %dom;
    while ( my $l = <$fh> ) {
        chomp $l;
        $l =~ s/^\s+|\s+$//g;
        next if $l =~ /^#/ || !length $l;
        if ( $l =~ /^content_root\s*:\s*(.+)/ ) {
            ( $dom{''}{content_root} = $1 ) =~ s/^\s+|\s+$//g;
        }
        elsif ( $l =~ /^alias\.(.+)\.(content_root|allowed_groups|locked_users)\s*:\s*(.+)/x ) {
            my ( $h, $k, $v ) = ( $1, $2, $3 );
            $v =~ s/^\s+|\s+$//g;
            $dom{$h} ||= { content_root => '', allowed_groups => [], locked_users => [] };
            if ( $k eq 'content_root' ) { $dom{$h}{content_root} = $v }
            else { $dom{$h}{$k} = [ grep { length } map { s/^\s+|\s+$//gr } split /,/, $v ] }
        }
    }
    close $fh;
    return %dom;
}

sub _domain_eff {
    my ( $user, @groups ) = @_;
    @groups = _group_closure(@groups);
    my %g   = map { $_ => 1 } @groups;
    my %dom = _read_domain_access();
    my ( %allowed, %locked );
    for my $h ( keys %dom ) {
        my @ag = @{ $dom{$h}{allowed_groups} || [] };
        if ( $h eq '' ) { $allowed{$h} = 1 if !@ag || grep { $g{$_} } @ag }
        else            { $allowed{$h} = 1 if @ag && grep { $g{$_} } @ag }
        $locked{$h} = 1
            if defined $user && grep { $_ eq $user } @{ $dom{$h}{locked_users} || [] };
    }
    my @eff = %locked ? ( grep { $allowed{$_} } keys %locked ) : ( keys %allowed );
    return ( \%dom, \@eff );
}

sub _domain_scopes {
    my ( $dom, $eff ) = _domain_eff(@_);
    return () unless @{$eff};
    my ( %seen, @sc );
    for my $h ( @{$eff} ) {
        my $cr = $dom->{$h}{content_root} // '';
        next unless length $cr;
        push @sc, $cr unless $seen{$cr}++;
    }
    return @sc;
}

sub _domain_home {
    my ( $dom, $eff ) = _domain_eff(@_);
    my @rooted = grep { length( $dom->{$_}{content_root} // '' ) } @{$eff};
    return ( @rooted == 1 ) ? $rooted[0] : '';
}

1;
