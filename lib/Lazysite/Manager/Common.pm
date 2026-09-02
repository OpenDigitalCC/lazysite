package Lazysite::Manager::Common;

# Shared path / deny / write / respond helpers for the manager (SM079). The
# per-request ambient context ($DOCROOT, $action, $auth_user) is set by the
# dispatcher as package variables, so the handler bodies that use these helpers
# move verbatim. The deny list @BLOCKED_PATHS is owned here.

use strict;
use warnings;
use Cwd            qw(realpath);
use Errno          ();                  # %! (errno names) for the permission-failure hint
use File::Basename qw(dirname basename);
use Fcntl          qw(:flock);
use JSON::PP       qw(encode_json);
use Lazysite::Util qw(log_event);
use Lazysite::Private ();
use Exporter 'import';
use Lazysite::Paths ();

our @EXPORT_OK = qw(validate_path is_blocked_path write_file_checked respond
    is_blocked_config is_blocked_upload_target upload_limits load_upload_limits _reset_upload_limits_cache
    _write_conf_key write_conf_key write_conf_content conf_batch path_out_of_scope outside_all_scopes reserved_roots path_is_reserved
    carveout_requirement carveout_refusal path_leads_to_carveout
    raw_html_page_refusal page_parse_refusal page_parse_issues processor_path brief_write_refusal);

our $DOCROOT;    # set by the script

# SM293: this site's engine tree - beside the docroot once migrated,
# inside it before. Asked, never computed, so both layouts work on one
# code path and a site migrates by moving the directory.
sub _lz { return Lazysite::Paths::lazysite_dir($DOCROOT) }
our $action    = '';    # current request action (for log attribution)
our $auth_user = '';    # current request user (for log attribution)

our @BLOCKED_PATHS = (
    'lazysite/auth/.secret',
    'lazysite/forms/.secret',
    'lazysite/auth/users',
    'lazysite/auth/groups',
    'lazysite/auth/user-settings.json',
);

# The engine-owned ("system") areas of the docroot: everything under lazysite/
# (secrets, ACLs, layouts, themes, forms). This is the SINGLE reserved-root
# definition - a visitor content_root, or any managed path, is "not permitted"
# when it IS or sits INSIDE one of these. _clean_content_root (Domains) asks
# path_is_reserved(); the render path keeps a module-free mirror in the
# processor's confine_content_root() (ADR 0001 - no module loads while
# rendering). Defined once here so the reserved set is not restated per caller.
our @RESERVED_ROOTS = ('lazysite');

sub reserved_roots { return @RESERVED_ROOTS }

# 1 if a docroot-relative path IS, or sits INSIDE, a reserved (system) root.
sub path_is_reserved {
    my ($rel) = @_;
    return 0 unless defined $rel && length $rel;

    # SM268 C2: NORMALISE before comparing, or the comparison is decorative.
    #
    # This stripped leading/trailing slashes and then compared literally, so
    # `./lazysite` and `.//lazysite/auth` were not "lazysite" and not under
    # "lazysite/" - they simply passed. An adversarial review used that to set a
    # domain's content_root to `./lazysite`, export the site, and download a
    # package advertised as carrying NO secrets that contained the account store,
    # the per-file ACLs and the session HMAC secret - which forges sysop
    # sessions.
    #
    # Collapse duplicate separators and drop `.` segments, so every spelling of
    # a path reaches the same comparison. `..` is rejected by the callers (and
    # by validate_path) rather than resolved here: this function answers "is this
    # a reserved area", not "where does this point".
    $rel =~ s{/+}{/}g;
    $rel =~ s{(?:^|/)\.(?=/|$)}{/}g;
    $rel =~ s{/+}{/}g;
    $rel =~ s{^/+|/+$}{}g;
    return 0 unless length $rel;

    for my $r (@RESERVED_ROOTS) {
        return 1 if $rel eq $r || index( $rel, "$r/" ) == 0;
    }
    return 0;
}

# SEC-2026-07: extensions that must never be written or served as site content -
# they execute (CGI/SSI/PHP) or reconfigure the web server. Case-insensitive.
# Kept in sync with the upload blocked_extensions default and the WebDAV
# blocklist. (perl doesn't care about extension, but the plugin runner is now
# registry-confined; these stop the *web server* executing an authored file.)
our @DANGEROUS_EXT
    = qw(pl pm cgi fcgi shtml shtm phtml php php3 php4 php5 phps phar htaccess htpasswd);
our $DANGEROUS_RE = do { my $alt = join '|', @DANGEROUS_EXT; qr/\.(?:$alt)\z/i };

# Resolve a relative path under DOCROOT, rejecting traversal (realpath must stay
# within DOCROOT). Returns { ok, full, rel } or { ok=>0, error }.
sub validate_path {
    my ($rel_path) = @_;
    return { ok => 0, error => "No path" } unless $rel_path;

    $rel_path =~ s{^/+}{};

    # SEC-2026-07 (F1): reject any ".." path segment outright. A legitimate
    # manager path is always docroot-relative and forward; a spelling like
    # "blog/../lazysite/auth/.secret" otherwise resolves (via the OS / realpath)
    # INTO a blocklisted subtree while the RAW string matched as unblocked -
    # is_blocked_path / is_blocked_config string-match on rel. That was a
    # blocklist bypass to the auth store (cookie-signing secret + password hashes
    # -> operator-cookie forgery, and writes into lazysite/). Rejecting ".." here
    # closes it at the source; deriving the canonical rel from the resolved path
    # below is the belt-and-braces that also collapses symlink pivots.
    return { ok => 0, error => "Invalid path" }
        if $rel_path =~ m{(?:\A|/)\.\.(?:/|\z)};

    my $full = "$DOCROOT/$rel_path";

    # SM510: resolve against the NEAREST EXISTING ancestor, not only the
    # immediate parent. dirname() alone meant a depth-two new path -
    # /newdir/sub/file.md - handed realpath a directory that does not exist,
    # got undef back, and the caller was told "Invalid path" about a path that
    # is perfectly fine (action_save and action_mkdir both create parents).
    # Found by the site agent as an incoherence that also blocks the
    # brief-first authoring the briefings themselves recommend. The walk is
    # SAFE where it matters: `..` was rejected above unconditionally, symlinks
    # in the EXISTING ancestors still collapse through realpath, and segments
    # that do not exist yet cannot contain a symlink to follow. The H3
    # containment test below is unchanged.
    my $anchor = $full;
    $anchor = dirname($anchor) until -e $anchor;

    # SM510 (the gate's catch): the walk above ALWAYS terminates - at the
    # docroot itself if nothing deeper exists - so on its own it made the
    # SM458 private branch unreachable for new paths, and a gated section's
    # deep path resolved as docroot WITHOUT the private tree's symlink
    # collapse and containment. t/unit/manager/90 refused to let that land.
    # So when the immediate parent is missing, BOTH trees walk to their
    # nearest existing ancestor and the DEEPER anchor claims the path; the
    # docroot wins ties, which preserves every pre-SM510 decision exactly
    # (a path whose parent exists never reaches this chooser).
    my $use_private = 0;
    if ( !-e $full && !-d dirname($full) ) {
        my $proot = Lazysite::Private::private_root($DOCROOT);
        my $pfull = defined $proot
            ? Lazysite::Private::private_path( $DOCROOT, $rel_path )
            : undef;
        if ( defined $pfull ) {
            my $panchor = $pfull;
            $panchor     = dirname($panchor) until -e $panchor;
            $use_private = 1
                if length($pfull) - length($panchor)
                < length($full) - length($anchor);
        }
    }
    my $real = realpath($anchor);

    # SEC-2026-07 (H3): boundary-safe containment. A bare index($real,$DOCROOT)
    # prefix test also passed for a SIBLING whose name is a string-superset of
    # the docroot (public_html vs public_html.bak), letting a write escape the
    # docroot. Require equality or a "$DOCROOT/" prefix.
    my $in_docroot
        = !$use_private
        && $real
        && ( $real eq $DOCROOT || index( $real, "$DOCROOT/" ) == 0 );

    # The blocklist string-matches on rel, so rel MUST be the CANONICAL in-docroot
    # path, never the request spelling. Derive it from the resolved realpath
    # ($real is the file itself, or its parent dir when the file does not exist
    # yet); re-attach the basename in that case. Callers get a full that is the
    # resolved absolute path too, so a symlink can't point a write elsewhere.
    my ( $canon, $rel );
    if ($in_docroot) {

        # SM510: re-attach everything below the anchor, not only the basename.
        # And normalise the tail: the old basename() rebuild never carried a
        # trailing slash, and rel is a KEY (ACLs, blocklist, audit) - a
        # 'members/' spelling must not mint a second key beside 'members'.
        $canon = ( -e $full ) ? $real : $real . substr( $full, length($anchor) );
        $canon =~ s{(?<=.)/+\z}{};
        ( $rel = $canon ) =~ s{\A\Q$DOCROOT\E/?}{};
    }
    else {
        # SM458: a NEW path inside a GATED section has no docroot parent to
        # resolve against, because gating MOVED the section into the private
        # store. So `$DOCROOT/intranet/filestore` does not exist, realpath
        # returns undef, and the operator is told "Invalid path" about a path
        # that is perfectly valid. Reproduced: mkdir in an open folder
        # succeeds, the same call inside a gated one is refused.
        #
        # THE COMMENT BELOW THIS BLOCK WARNS AGAINST THE OBVIOUS FIX, and it
        # is right: widening the containment test above to accept two prefixes
        # would make a CVE-class check weaker to add a feature. So the docroot
        # check is left exactly as it was, and this is a SECOND, SEPARATE
        # check against the private root - each one strict, each one
        # boundary-safe in its own tree. A path must be wholly inside one of
        # them; neither test has been loosened.
        #
        # The `..` rejection above still applies unconditionally and is not
        # reached from here.
        my $proot = Lazysite::Private::private_root($DOCROOT);
        my $pfull = defined $proot
            ? Lazysite::Private::private_path( $DOCROOT, $rel_path )
            : undef;
        return { ok => 0, error => "Invalid path" }
            unless defined $proot && defined $pfull;

        # SM510: the same nearest-existing-ancestor walk as the docroot
        # branch, for the same reason - a deep new path inside a gated
        # section is as ordinary as a shallow one.
        my $panchor = $pfull;
        $panchor = dirname($panchor) until -e $panchor;
        my $preal = realpath($panchor);
        return { ok => 0, error => "Invalid path" }
            unless $preal && ( $preal eq $proot || index( $preal, "$proot/" ) == 0 );

        my $pcanon
            = ( -e $pfull ) ? $preal : $preal . substr( $pfull, length($panchor) );
        $pcanon =~ s{(?<=.)/+\z}{};                # SM510: rel is a key, never 'members/'
        ( $rel = $pcanon ) =~ s{\A\Q$proot\E/?}{};

        # rel stays the DOCROOT key - the ACL store, the blocklist and every
        # audit line are keyed on it - so the public spelling is rebuilt from
        # it rather than carried from the private tree.
        $canon = "$DOCROOT/$rel";
    }

    # SM286: `rel` is the docroot-relative KEY and never changes - the ACL store,
    # the blocklist and every audit line are keyed on it. `full` is WHERE THE
    # BYTES ARE, which may be the private store.
    #
    # Deliberately bolted on AFTER the validation above rather than woven into
    # it. That block carries two CVE-class fixes (F1's `..` rejection and H3's
    # boundary-safe containment) and both reason about the docroot; rewriting
    # them to span two trees to add a feature is how a fix gets undone. So the
    # request is still validated against the docroot exactly as before, and only
    # then resolved.
    #
    # resolve_for_write, not resolve: a NEW file inside a gated folder must be
    # created privately. Otherwise the first save into a moved-out section makes
    # a public directory for it and half-publishes the section, via an operation
    # nobody thinks of as a permission change.
    my ( $abs, $where ) = Lazysite::Private::resolve_for_write( $DOCROOT, $rel );
    return {
        ok    => 1,
        full  => ( $where eq 'private' ? $abs : $canon ),
        rel   => $rel,
        store => ( $where || 'public' ),

        # The docroot location regardless of where the content lives, for the
        # callers that legitimately need it - the move in and out of the store,
        # and anything reporting on a stray public copy.
        public_full => $canon,
    };
}

# SEC-2026-07 (M2): dav_scope confines a token/partner credential to one content
# subtree. WebDAV enforces it in lazysite-dav.pl::authorise; the MCP and control-
# API file channels must enforce the SAME confinement, or a scoped credential
# that also holds api/mcp reaches the whole content namespace over those
# channels. Returns 1 if the content path is OUTSIDE the scope, else 0. An
# empty/undef scope confines nothing (an unscoped credential). The lazysite/
# theme-authoring namespace is NOT a content path and is governed by
# manage_themes/manage_layouts, so callers skip it (parity with WebDAV, where
# dav_scope "does not apply" to the layouts carve-out).
sub path_out_of_scope {
    my ( $scope, $path ) = @_;
    return 0 unless defined $scope && length $scope;
    ( my $s = $scope ) =~ s{^/+|/+$}{}g;
    return 0 unless length $s;
    ( my $rel = defined $path ? $path : '' ) =~ s{^/+}{};
    $rel =~ s{/+$}{};
    return ( $rel eq $s || index( $rel, "$s/" ) == 0 ) ? 0 : 1;
}

# SM661: EVERY ARGUMENT NAME THAT CARRIES A CONTENT PATH.
#
# The MCP dispatcher's two confinement passes - the SM155 scope check and the
# SM268 H4 carve-out check - iterated a hardcoded qw(path to from). create_page
# declares `slug`; rename_page declares `old` and `new`. Neither name was
# inspected, so neither call was confined, and a grant scoped to one domain
# created and moved content in another. Nothing was malformed: the calls were
# well-formed and the tools did exactly what they advertise.
#
# Named ONCE here, read by both passes, and pinned by t/lint/91 - which refuses
# a path_aware tool that declares a property this list does not know about. A
# longer hardcoded list would be the same defect in a year; the lint is what
# makes the next differently-named path argument a decision rather than a
# discovery.
#
# `host` is deliberately absent: it is a domain name, not a content path, and
# read_nav resolves it through the domain registry rather than as a path.
our @PATH_ARGS = qw(path to from slug old new);

# SM155: a user may be confined by SEVERAL groups' content roots (the union -
# an editor of clienta AND clientb). Returns 1 iff the set is non-empty AND the
# path lies outside EVERY scope (i.e. deny); an empty set confines nothing
# (unconfined). Reuses path_out_of_scope per scope, so the lazysite/ carve-out
# and boundary-safe matching are identical to the single-scope path.
sub outside_all_scopes {
    my ( $scopes, $path ) = @_;
    return 0 unless ref $scopes eq 'ARRAY' && @$scopes;
    for my $s (@$scopes) {
        return 0 unless path_out_of_scope( $s, $path );    # inside one => allowed
    }
    return 1;
}

# The carve-outs from the whole-lazysite/ denial, named ONCE. is_blocked_path
# asks "is this path one of them", path_leads_to_carveout asks "is this
# directory on the way to one" - a listing must offer lazysite/layouts even
# though nothing may be read at that path itself. Two lists would drift, and the
# way they would drift is a directory the file browser can no longer enter.
# SM421/F2: 'lazysite/themes/' REMOVED (release manager's call, 2026-08-20).
#
# It exempted a store that has never existed. Real themes live under
# lazysite/layouts/<layout>/themes/<theme>/, governed by the layouts elevation;
# 88f16b4 added this prefix in one batch with layouts/ and nav.conf, two areas
# that ARE real, on the assumption this was a third. Nothing in the engine has
# ever resolved a top-level lazysite/themes/.
#
# So it was inert - and an inert carve-out is an under-gated write path waiting
# for the first feature to use the name: MCP and the cookie file surface would
# have allowed writes there that WebDAV (which never had the exemption) refuses.
#
# The risk accepted in removing it: an agent holding manage_themes could have
# written under that path THROUGH this carve-out, and such files are now
# invisible to the file layer. To check a site:
#
#     ls -la <docroot>/lazysite/themes/    # expected: no such directory
#
# Nothing in the fleet is expected to have it; the check is cheap and the
# finding would be interesting rather than damaging (the files are still on
# disk, just no longer reachable through the file surface).
our @LAZYSITE_OPEN_PREFIXES
    = ( 'lazysite/forms/submissions/', 'lazysite/layouts/', 'lazysite/brands/' );
our @LAZYSITE_OPEN_EXACT = ('lazysite/nav.conf');

sub _is_carveout {
    my ($rel) = @_;
    for my $e (@LAZYSITE_OPEN_EXACT) { return 1 if $rel eq $e }
    for my $p (@LAZYSITE_OPEN_PREFIXES) {

        # SM509: the DIRECTORY ITSELF is part of its own carve-out. The prefix
        # test alone matched only paths UNDER the store, so listing
        # lazysite/forms/submissions - the exact call the manager's submissions
        # panel makes - was refused as "blocked lazysite tree", and the panel
        # read the refusal as "No submissions yet" while the API read five rows
        # from the same store. A boundary bug wearing an empty-state costume.
        return 1 if index( $rel, $p ) == 0 || "$rel/" eq $p;
    }
    return 0;
}

# 1 if $rel is a DIRECTORY that some carve-out lives under, so a listing may
# show it even though the path itself is not readable.
sub path_leads_to_carveout {
    my ($rel) = @_;
    return 0 unless defined $rel && length $rel;
    $rel =~ s{^/+|/+$}{}g;
    return 0 unless length $rel;
    for my $c ( @LAZYSITE_OPEN_PREFIXES, @LAZYSITE_OPEN_EXACT ) {
        return 1 if index( $c, "$rel/" ) == 0;
    }
    return 0;
}

# The hard deny list (exact paths) plus the *.pl rule.
sub is_blocked_path {
    my ($rel_path) = @_;
    for my $blocked (@BLOCKED_PATHS) {
        if ( $rel_path eq $blocked ) {
            log_event( 'WARN', $action, 'blocked path access', path => $rel_path, user => $auth_user );
            return "'$rel_path' is on this site's blocked-path list.";
        }
    }
    # SEC-2026-07 (H4): the SENSITIVE part of the lazysite/ management tree is
    # off-limits to the generic file editor - the auth store (.secret, hashes,
    # ACLs, sessions), logs, cache, backups, the built-in templates, the manager
    # UI chrome, lazysite.conf, and form CONFIGS (smtp.conf etc. hold secrets).
    # The capability-/scope-gated content areas that partners legitimately manage
    # by path - layouts/, themes/, nav.conf - and form SUBMISSIONS (operator
    # reviews entries) stay reachable: those are guarded by manage_layouts/
    # manage_themes/manage_nav + dav_scope, not by this path blocklist.
    if ( $rel_path =~ m{\Alazysite/} && !_is_carveout($rel_path) ) {
        log_event( 'WARN', $action, 'blocked lazysite tree', path => $rel_path, user => $auth_user );
        return "'$rel_path' is inside the reserved lazysite/ tree, which the "
            . 'file surfaces do not write. The parts a partner legitimately '
            . 'manages - layouts, themes, nav and form submissions - are '
            . 'carve-outs reached by their own capabilities.';
    }
    # SEC-2026-07: never write/serve an executable or server-config extension.
    if ( $rel_path =~ $DANGEROUS_RE ) {
        log_event( 'WARN', $action, 'blocked path access', path => $rel_path, user => $auth_user );
        return "'$rel_path' has an executable or server-config extension, "
            . 'which is never written or served whatever the folder.';
    }

    # A BRAND TEMPLATE IS EXECUTABLE INPUT, and the brand folder is otherwise
    # ordinary operator content - a logo, a font, a colour - which is why it is
    # carved out above. A pandoc LaTeX template is different in kind: its text
    # reaches xelatex, and `\input{/etc/passwd}` in it is read at render time
    # by the CGI user. Uploading one would turn manage_content, which today
    # authors pages, into "read any file this server can", which is not a
    # grant the Files page is entitled to hand out.
    #
    # md-to-pdf never passes -shell-escape, so this is a file READ and not
    # command execution - checked, and stated rather than assumed.
    #
    # Templates therefore arrive the way they always have: placed on the server
    # by somebody who already holds that authority. SM707 asks whether the
    # manager should ever offer it.
    if ( $rel_path =~ m{\Alazysite/brands/}i
        && $rel_path =~ /\.(?:tex|latex|sty|cls|lua)\z/i )
    {
        log_event( 'WARN', $action, 'blocked brand template via manager',
            path => $rel_path, user => $auth_user );
        return "a brand template cannot be uploaded here. Its text reaches the "
            . 'PDF typesetter, so a file that can name another file could read '
            . 'one - .tex, .latex, .sty, .cls and .lua are refused in the brand '
            . 'folder for that reason, deliberately and permanently. Brand '
            . 'assets that are only data - fonts, logos, images - are accepted.';
    }
    return 0;
}

# SM422: is this path inside ANY configured submission store?
#
# The default store, plus each file-handler `path` - the same set the control
# API's form-submissions route admits. Loaded through Manager::Plugins so there
# is one definition of "a submission store" rather than a prefix here and an
# allowlist there.
#
# Fails SAFE and QUIET: if the handler config cannot be read the answer is the
# default prefix alone, which is what this function did before it knew about
# configured stores. A store that cannot be enumerated must not become a store
# that is ungated.
sub _is_submission_store_path {
    my ($rel) = @_;

    # SM509: the store DIRECTORY answers as store too, so a listing of it is
    # capability-gated (read_submissions|manage_forms) exactly like the files
    # in it - opened by the carve-out, governed by the requirement.
    return 1
        if index( $rel, 'lazysite/forms/submissions/' ) == 0
        || $rel eq 'lazysite/forms/submissions';
    my @dirs = eval {
        require Lazysite::Manager::Plugins;
        Lazysite::Manager::Plugins::submission_store_dirs();
    };
    return 0 unless @dirs;
    for my $d (@dirs) {
        next unless defined $d && length $d;
        return 1 if index( $rel, "$d/" ) == 0 || $rel eq $d;    # SM509
    }
    return 0;
}

# SM268 H4: the carve-outs above are reachable by PATH on the generic file
# surface, and each of them is governed by a CAPABILITY on every other plane.
# nav.conf needs manage_nav for nav-read/nav-save and over WebDAV; the
# submission store needs read_submissions (or manage_forms) for
# form-submissions and read_form_submissions, and WebDAV refuses it outright.
# read_file/write_file asked only "is this path blocked", so a partner holding
# manage_content alone could read every submission - names, email addresses,
# message bodies - and rewrite the site navigation, defeating the three
# capabilities that exist to say otherwise. The blocklist cannot decide this
# itself: it takes a path and no caller identity, and the manager UI and its
# agents legitimately reach both paths when they hold the capability.
#
# So the requirement is stated ONCE here, and the two dispatchers that expose
# the file surface by path (the control API and MCP) apply it against the
# caller's resolved capabilities, alongside the scope and blocklist gates they
# already run. An empty `caps` list means "no capability reaches this" - the
# submission store is written by the form handler, never by hand.
#
# Returns { caps => [...], mode, why } or undef if the path is not governed.
sub carveout_requirement {
    my ( $rel, $mode ) = @_;
    return undef unless defined $rel && length $rel;
    $mode = 'read' unless defined $mode && $mode eq 'write';

    my $r = $rel;
    $r =~ s{/+}{/}g;
    $r =~ s{(?:^|/)\.(?=/|$)}{/}g;
    $r =~ s{/+}{/}g;
    $r =~ s{^/+|/+$}{}g;
    return undef unless length $r;

    if ( $r eq 'lazysite/nav.conf' ) {
        return { caps => ['manage_nav'], mode => $mode,
            why => 'the site navigation is governed by the manage_nav capability' };
    }

    # The literal prefix the blocklist carves out. A store the operator has
    # configured ELSEWHERE under lazysite/ is still blocked outright; one under
    # the content tree is ordinary content, confined by dav_scope.
    # SM422: EVERY CONFIGURED STORE, not just the default path.
    #
    # This keyed on the fixed prefix while the control API's form-submissions
    # route resolves through submission_store_dirs - the SM268 H1 allowlist of
    # the default store PLUS each file-handler's configured `path`. The two
    # agree for a default install and DIVERGE the moment an operator points a
    # handler somewhere else, which submission_store_dirs explicitly allows
    # (a store under the content tree, say). Reproduced: with a handler at
    # `path: content/leads`, a grant holding only manage_content was refused
    # /lazysite/forms/submissions/contact.jsonl and SERVED
    # /content/leads/data.jsonl - the same kind of data, two guards, and the
    # read gate depending on which surface reached it.
    #
    # One definition now. The generalisation is deliberate rather than
    # constraining the layout: forbidding a store outside lazysite/forms/ would
    # remove a configuration the code supports and an operator may already be
    # using.
    if ( _is_submission_store_path($r) ) {
        return { caps => [], mode => $mode,
            why => 'the submission store is append-only: the form handler writes it' }
            if $mode eq 'write';
        return { caps => [ 'read_submissions', 'manage_forms' ], mode => $mode,
            why => 'form submissions carry the data visitors sent you' };
    }

    return undef;
}

# The refusal text for a governed path the caller cannot reach, or undef when
# it can. $caps is the caller's resolved capability hash.
sub carveout_refusal {
    my ( $rel, $mode, $caps ) = @_;
    my $req = carveout_requirement( $rel, $mode );
    return undef unless $req;
    $caps ||= {};
    for my $c ( @{ $req->{caps} } ) {
        return undef if $caps->{$c};
    }
    my $needs = @{ $req->{caps} }
        ? ( 'It needs the ' . join( ' or ', @{ $req->{caps} } ) . ' capability.' )
        : 'No capability reaches it on this channel.';
    log_event( 'WARN', $action, 'blocked carve-out path',
        path => $rel, user => $auth_user );
    return "'$rel' is not $req->{mode}able by path: $req->{why}. $needs";
}

# A permission failure is server-truthful but sysop-opaque ("Permission
# denied" told the field nothing actionable) - name the likely cause and the
# fix. Appended only for EACCES/EPERM, at this layer because it is the one
# that still has the errno.
sub _perm_hint {
    return ( $!{EACCES} || $!{EPERM} )
        ? ' (the file is not writable by the web-server user - run: lazysite check --fix)'
        : '';
}

# Write a file ATOMICALLY: write a temp sibling, then rename(2) it over the
# target (atomic on POSIX). A concurrent reader therefore always sees either the
# old complete file or the new complete file - never a truncated or half-written
# one, which is how two racing config-set saves once truncated lazysite.conf to a
# single key. Any failure removes the TEMP only; the existing file is never
# unlinked (the old in-place open '>' both truncated up-front and unlinked the
# real file on error). Returns (ok, error).
sub write_file_checked {
    my ( $path, $content ) = @_;
    my $tmp = "$path.$$.tmp";
    open my $fh, '>:utf8', $tmp
        or return ( 0, "Cannot write file: $!" . _perm_hint() );
    unless ( print {$fh} $content ) {
        my $err  = "$!";
        my $hint = _perm_hint();
        close $fh;
        unlink $tmp;
        return ( 0, "Write failed: $err$hint" );
    }
    unless ( close $fh ) {
        my $err  = "$!";
        my $hint = _perm_hint();
        unlink $tmp;
        return ( 0, "Close failed: $err$hint" );
    }
    # rename adopts the temp's mode, so carry the target's existing mode across
    # (a fresh file keeps the umask default the direct-open path would have set).
    if     ( my @st = stat $path ) { chmod $st[2] & 07777, $tmp }
    unless ( rename $tmp, $path ) {
        my $err  = "$!";
        my $hint = _perm_hint();
        unlink $tmp;
        return ( 0, "Rename failed: $err$hint" );
    }
    return ( 1, undef );
}

# Emit a JSON response (200).
# SM238: where the render processor lives. Both the control API (page preview)
# and the domain preview shell it, and the domain preview moved into
# Manager::Domains - so this is defined ONCE here rather than copied, which is
# the class of duplication t/lint/17 exists to catch.
sub processor_path {
    my $lp  = $ENV{LAZYSITE_PROCESSOR};
    my $dir = ( defined $lp && length $lp )
        ? File::Basename::dirname($lp)
        : "$DOCROOT/../cgi-bin";
    return "$dir/lazysite-processor.pl";
}

sub respond {
    my ($data) = @_;

    # SM353: `ok` is a BOOLEAN, and it is coerced here rather than at the ~130
    # places that set it.
    #
    # The filing reported it as a per-surface difference - the control API
    # answering 1 where MCP answered true - which understated it. `ok` was
    # whatever each handler happened to write, on BOTH surfaces: MCP's
    # describe_capabilities set JSON::PP::true and its validate_page set 1. So
    # there was no rule to follow, only a hundred-odd independent decisions that
    # agreed by accident.
    #
    # A caller written against one surface and pointed at the other fails
    # silently, because `res.ok === true` succeeds on one and not the other
    # while `if (res.ok)` passes on both - type-dependent rather than
    # value-dependent, and only visible when someone ports code between
    # channels, which is exactly what the parity work invites.
    #
    # THIS IS A COMPATIBILITY BREAK, taken deliberately before the freeze. A
    # script testing `ok == 1` in Perl or `ok === 1` in JavaScript will change
    # behaviour. `true` is the side to standardise on: it is what the JSON
    # Schema declares and what MCP already emitted for its most-called tool.
    $data->{ok} = $data->{ok} ? JSON::PP::true : JSON::PP::false
        if ref $data eq 'HASH' && exists $data->{ok};

    # encode_json already emits UTF-8 bytes; print raw (a :utf8 layer would
    # double-encode non-ASCII content into mojibake).
    binmode(STDOUT);
    print "Status: 200 OK\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n\r\n";
    print encode_json($data);
}

our $_upload_limits_cache;

# PC-10/SM516: the comma list a conf key carries, as both blocked-path keys
# parse it - split on commas, drop empties, strip leading and trailing slashes.
# The blocked_extensions arm is the `lc` variant and keeps its own two lines.
sub _conf_list {
    my ($v) = @_;
    return [
        map { my $p = $_; $p =~ s{^/+|/+$}{}g; $p }
            grep { length }
            split /\s*,\s*/, $v
    ];
}

sub load_upload_limits {
    local $_;    # SM420: while(<>) assigns the GLOBAL $_
    my %limits = (
        max_bytes     => 10 * 1024 * 1024,
        blocked_paths => [ qw(
                lazysite/auth lazysite/forms lazysite/cache
                lazysite/manager cgi-bin manager
        ) ],
        blocked_extensions => [@DANGEROUS_EXT],    # SEC-2026-07: block active content
        rate_count         => 60,
        rate_bytes         => 500 * 1024 * 1024,
    );

    my $conf_path = _lz() . "/lazysite.conf";
    return \%limits unless -f $conf_path;

    my $new_key_seen = 0;
    my $old_key_seen = 0;
    open my $fh, '<', $conf_path or return \%limits;

    # SM419: `while (<$fh>)` assigns the GLOBAL $_, so without this a caller
    # doing `grep { is_blocked_config($_) } @list` has the element under test
    # destroyed mid-comparison - is_blocked_config -> upload_limits ->
    # load_upload_limits, and $_ never comes back. Worse, upload_limits
    # memoises, so ONLY THE FIRST call corrupts: the first element of the
    # first such grep in a process comes out empty and every later one is
    # fine, which reads like anything except what it is. Found when the SM419
    # summary filter dropped its first path. The localisation itself is the
    # one at the top of this sub (SM420); a second in the same scope only
    # re-saves a value already saved.
    while (<$fh>) {
        if (/^manager_upload_max_mb\s*:\s*(\S+)/) {
            my $mb = $1;
            if ( $mb =~ /^\d+$/ && $mb > 0 ) {
                $limits{max_bytes} = $mb * 1024 * 1024;
            } else {
                log_event( 'WARN', 'config',
                    'invalid manager_upload_max_mb', value => $mb );
            }
        }
        elsif (/^manager_blocked_paths\s*:\s*(.+)/) {
            my $v = $1;
            $v =~ s/\s+$//;
            if ( length $v ) {
                $limits{blocked_paths} = _conf_list($v);
            }
            $new_key_seen = 1;
        }
        elsif (/^manager_upload_blocked_paths\s*:\s*(.+)/) {
            # Deprecated alias; only honoured if the new key
            # is absent. The new-key check happens after the
            # loop because they may appear in either order.
            my $v = $1;
            $v =~ s/\s+$//;
            if ( length $v ) {
                $limits{_deprecated_blocked_paths} = _conf_list($v);
            }
            $old_key_seen = 1;
        }
        elsif (/^manager_upload_blocked_extensions\s*:\s*(.+)/) {
            my $v = $1;
            $v =~ s/\s+$//;
            if ( length $v ) {
                $limits{blocked_extensions} = [
                    map { lc $_ }
                        grep { length }
                        split /\s*,\s*/, $v
                ];
            }
        }
        elsif (/^manager_upload_rate_count\s*:\s*(\S+)/) {
            my $n = $1;
            if ( $n =~ /^\d+$/ ) {
                $limits{rate_count} = $n + 0;
            } else {
                log_event( 'WARN', 'config',
                    'invalid manager_upload_rate_count', value => $n );
            }
        }
        elsif (/^manager_upload_rate_mb\s*:\s*(\S+)/) {
            my $mb = $1;
            if ( $mb =~ /^\d+$/ ) {
                $limits{rate_bytes} = $mb * 1024 * 1024;
            } else {
                log_event( 'WARN', 'config',
                    'invalid manager_upload_rate_mb', value => $mb );
            }
        }
    }
    close $fh;

    # Apply the deprecated alias only if the new key was not set.
    # Log INFO so operators know to rename.
    if ( $old_key_seen && !$new_key_seen
        && exists $limits{_deprecated_blocked_paths} ) {
        $limits{blocked_paths} = delete $limits{_deprecated_blocked_paths};
        log_event( 'INFO', 'config',
            'manager_upload_blocked_paths is deprecated; '
                . 'rename to manager_blocked_paths in lazysite.conf' );
    }
    delete $limits{_deprecated_blocked_paths};

    return \%limits;
}

sub upload_limits {
    $_upload_limits_cache //= load_upload_limits();
    return $_upload_limits_cache;
}

# SM730: THESE RETURN A REASON, not a bare 1.
#
# Every caller uses them in boolean context, so a truthy string changes nothing
# for them and gives the ones that report to a person something to report. The
# upload path answered "Blocked target" and named neither the rule nor the
# extension, in the same session where a capability refusal read "(needs
# manage_data)" - the same kind of event answered to very different standards,
# and the weaker one in the place with less context to fall back on.
#
# The reason was already known here and thrown away: both blockers log WHY and
# then returned 1.
sub is_blocked_config {
    my ( $rel_path, $check_extensions ) = @_;

    # Form SUBMISSIONS are append-only data the manager is meant to view and prune
    # (the editor opens them read-only). They live under lazysite/forms/submissions,
    # which is otherwise swallowed by the lazysite/forms block that protects the
    # form CONFIGS (smtp.conf etc. hold secrets). Exempt the submissions subtree so
    # the file editor / submissions viewer can read them.
    return 0 if $rel_path =~ m{^lazysite/forms/submissions(?:/|$)};

    my $limits = upload_limits();

    for my $prefix ( @{ $limits->{blocked_paths} } ) {
        next unless length $prefix;
        if ( $rel_path eq $prefix
            || index( $rel_path, "$prefix/" ) == 0 ) {
            log_event( 'WARN', $action, 'blocked by config (path)',
                path => $rel_path, prefix => $prefix,
                user => $auth_user );
            return "'$prefix' is a blocked path on this site, so '$rel_path' "
                . 'cannot be written there.';
        }
    }

    return 0 unless $check_extensions;

    my ($ext) = $rel_path =~ /\.([^.\/]+)$/;
    if ( defined $ext ) {
        my $lc = lc $ext;
        for my $blocked ( @{ $limits->{blocked_extensions} } ) {
            if ( $lc eq $blocked ) {
                log_event( 'WARN', $action,
                    'blocked by config (extension)',
                    path => $rel_path, extension => $lc,
                    user => $auth_user );
                return ".$lc files are not accepted here. This folder refuses "
                    . 'them because their contents are executed rather than '
                    . 'served - a brand template reaches the PDF typesetter, '
                    . 'so a file that can name another file could read one.';
            }
        }
    }
    return 0;
}

sub is_blocked_upload_target {
    my ($rel_path) = @_;
    return is_blocked_config( $rel_path, 1 );
}

sub _reset_upload_limits_cache { $_upload_limits_cache = undef }

# SM189: reject a content page that ships script-capable RAW output. A page whose
# front matter declares `api: true` or `raw: true` together with a script-capable
# content_type (text/html, XHTML, SVG) bypasses the layout + theme and is served
# as text/plain by peek_content_type (ADR 0006) - so it is a broken page, not an
# artifact, and it evades the no-CDN theme guard. Every content write (manager
# save, MCP, WebDAV PUT) calls this and refuses on a non-undef return. A genuine
# artifact (a non-script content_type, e.g. application/json / text/csv) passes.
# The api/raw/content_type matching mirrors the processor's front-matter parse and
# peek_content_type, so write-refusal and serve-time downgrade agree.
# SM504: once the briefs plugin is enabled on a site, a .brief WRITE is
# refused - the sysop's instruction, relayed with the field agent's
# argument verbatim: a brief is the record of WHY something was done, often
# the channel between two agents who never speak, so its failure mode is
# not a broken page anyone notices - it is a note nobody reads, found
# months later by someone looking for a decision that was, as far as its
# author knew, written down. Every signal the writer gets says it worked:
# 201, file on disk, reads back byte-identical. None is wrong on its own
# terms, which is what makes the combination misleading.
#
# GATED ON THE PLUGIN, NEVER THE VERSION (B3): migration is per site, as
# each site is next revisited - a half-migrated estate is the NORMAL state
# for a long time, and a site still on sidecars must keep working
# indefinitely. Reads are untouched (B4): an existing sidecar stays
# readable so an agent can see what is there before migrating it.
sub brief_write_refusal {
    my ($rel) = @_;
    return undef unless defined $rel && $rel =~ /\.brief\z/;
    require Lazysite::Manager::Plugins;
    # The api and mcp set Common's $DOCROOT in their setup blocks; the DAV
    # process never does - it carries the docroot in the environment. An
    # empty docroot must read as "cannot tell", never as "disabled": no
    # refusal, the write proceeds, exactly as before SM504.
    my $droot = ( defined $DOCROOT && length $DOCROOT ) ? $DOCROOT : ( $ENV{DOCUMENT_ROOT} // '' );
    return undef unless length $droot;
    # SM557: the package is require'd at runtime, so this file mentions the
    # variable once by design - t/lint/04 refuses the 'used only once' warning.
    no warnings 'once';
    local $Lazysite::Manager::Plugins::DOCROOT = $droot;
    return undef
        unless eval { Lazysite::Manager::Plugins::plugin_enabled('plugins/briefs.pl') };
    return 'This site holds briefs in the brief store, not in .brief sidecar '
        . 'files - a sidecar written here would be an inert file no listing '
        . 'shows and no migration imports, a note nobody reads. Append to the '
        . "record instead: append_brief over MCP, or brief-append on the "
        . 'control API, with {path, entry}. Reading an existing sidecar still '
        . 'works.';
}

sub raw_html_page_refusal {
    my ($content) = @_;
    return undef unless defined $content;
    return undef unless $content =~ /\A---\s*\n(.*?)\n---\s*\n/s;    # front-matter block
    my $fm = $1;
    return undef
        unless $fm =~ /^api\s*:\s*true\b/mi || $fm =~ /^raw\s*:\s*true\b/mi;
    my ($ct) = $fm =~ /^content_type\s*:\s*(.+?)\s*$/mi;
    return undef
        unless defined $ct
        && $ct =~ m{^\s*(?:text/html|application/xhtml\+xml|image/svg\+xml)\b}i;
    # SM228: name the alternative, not only the prohibition. The reader here is
    # usually someone who wants a self-contained HTML file served unchanged, and
    # `raw:` is the front-matter key whose name invites exactly that. The answer -
    # publish it as a STATIC FILE, which lazysite serves byte-for-byte and which
    # accepts .html/.js on every authoring channel - is a different mechanism, and
    # nothing previously connected the two.
    return
        "This page declares a raw HTML content type ($ct), which a content page "
        . "may not use: raw HTML/SVG bypasses the layout and theme and is served "
        . "as plain text (ADR 0006), and external CSS/font/CDN links are refused. "
        . "What to do instead: to publish a self-contained HTML file unchanged, "
        . "write it as a STATIC FILE (e.g. app/index.html) - a .html with no .md "
        . "source is served byte-for-byte, with no Markdown pipeline, layout or "
        . "theme, and .html/.js are writable on every authoring channel. For an "
        . "ordinary page, author Markdown and let the layout and theme style it. "
        . "For a genuine data artifact, use a non-script content type such as "
        . "application/json.";
}

# SM729: THE PAGE-PARSE GUARD LIVES HERE, beside raw_html_page_refusal, because
# both stacks write pages and a guard in one script cannot reach the other.
#
# WHY IT MOVED. SM708 built this as a private sub in lazysite-mcp.pl, so the
# WebDAV PUT path never saw it - proved in the field on 0.11.10, where a
# deliberately unparseable body was ACCEPTED over WebDAV on an auth-enabled site
# that interpolates auth variables, and therefore renders with every
# substitution dead. Nobody had decided WebDAV should be exempt; the guard was
# simply in a file WebDAV cannot reach.
#
# SM189 had already settled the pattern one function above: a content refusal
# belongs in this module, both write paths call it, and the DAV path refuses
# BEFORE the rename so nothing lands on disk. This finishes that pattern rather
# than inventing a second one - which is SM430's argument generally, one answer
# per operation wherever it is invoked.
sub page_parse_issues {
    my ($body) = @_;
    my $issues = [];
    return () unless defined $body && $body =~ /\[%/;

    # Strip what the processor protects, plus anything ambiguous.
    my ( @keep, $in_fence );
    for my $line ( split /\n/, $body ) {
        if ( $line =~ /^[ \t]{0,3}(?:```|~~~)/ ) { $in_fence = !$in_fence; next }
        next if $in_fence;
        next if $line =~ /^(?: {4}|\t)/;    # indented code block
        push @keep, $line;
    }
    my $text = join "\n", @keep;
    $text =~ s/`[^`\n]*`//g;                     # inline code
    return () unless $text =~ /\[%/;

    # Lazily loaded: the MCP script does not otherwise need Template, and a host
    # without it should lose the CHECK rather than gain a false refusal.
    return () unless eval { require Template; 1 };

    my $tt  = eval { Template->new( {} ) } or return;
    my $out = '';
    return () if $tt->process( \$text, {}, \$out );

    my $err = $tt->error // '';
    return () unless $err =~ /parse error/;

    my $line = ( $err =~ /line (\d+)/ ) ? $1 + 0 : undef;
    ( my $detail = $err ) =~ s/\s+/ /g;
    $detail =~ s/^file error - //;
    push @$issues, {
        kind => 'template-parse',
        ( defined $line ? ( line => $line ) : () ),
        message =>
            "the page's template syntax does not parse, so EVERY [% %] on it "
            . "would render literally - not only the one at fault. The engine "
            . "falls back to the raw body on a parse error, which is why the page "
            . "would still appear, with every variable dead. Commonest cause: a "
            . "literal [% in page JavaScript, often in a regular expression "
            . "written to detect an un-interpolated template. Put the value in a "
            . "data- attribute and read it from there instead, or split the "
            . "literal. Parser said: $detail",
    };
    return @$issues;
}

# The write-path refusal, shared by both stacks. Returns a message or undef.
sub page_parse_refusal {
    my ( $path, $content ) = @_;
    return undef unless defined $path    && $path    =~ /\.md$/i;
    return undef unless defined $content && $content =~ /\[%/;
    my $body = $content;
    $body =~ s/\A---\n.*?\n---\n//s;
    my @issues = page_parse_issues($body);
    return @issues ? $issues[0]{message} : undef;
}

# =========================================================================
# SM255: ONE write path for lazysite.conf
# =========================================================================
#
# The commit is a property of WRITING THIS FILE, not of the action that happened
# to do it. A sysop does not know or care whether a change arrived through
# config-set, domain-set or the CLI - they know the file changed, and it should
# be recorded once, the same way, every time. Before this, config-set committed
# and the domain verbs did not, on the same file.
#
# So: no caller commits, and no caller may skip committing. A caller may only
# GROUP writes into one commit, via conf_batch - which is not the same as opting
# out, because the batch always commits at the end.
#
# WRITE STRATEGY. The two writers this replaces used incompatible techniques,
# each introduced for a real reason:
#   - _write_conf_key wrote via temp+rename (atomic);
#   - Domains::_write wrote IN PLACE, on the grounds that temp+rename drops a
#     site-user's ownership on the new inode.
# Only one can survive, and the atomic one must: READERS OF THIS FILE ARE
# LOCK-FREE BY DESIGN, so they depend on the rename to never observe a partial
# file. t/unit/manager/47 asserts exactly that, and an in-place write fails it -
# the lock serialises writers and does nothing for a concurrent reader.
# The ownership concern the in-place write addressed is covered another way:
# write_file_checked carries the old mode across to the temp file, and
# lazysite/ is setgid (2775) so the group is inherited. Owner may flip between
# the two legitimate writers - the site user and the web-server CGI - and mode
# 0664 keeps both able to write, which is what the installer's group-write pass
# exists to guarantee.
our $CONF_BATCH;    # set by conf_batch() while a grouped write is in flight

sub _conf_path_of { return _lz() . "/lazysite.conf" }

# Group several conf writes into ONE content-history entry. domain_add writes
# half a dozen keys; without this, one registration would read as six separate
# acts in the history. Nested calls join the outer batch - the outermost owns
# the commit.
sub conf_batch {
    my ( $message, $code ) = @_;
    return $code->() if $CONF_BATCH;    # already batching: the outer one commits
    local $CONF_BATCH = { message => $message, dirty => 0 };
    my $r = eval { $code->() };
    my $e = $@;
    _commit_conf( $CONF_BATCH->{message} ) if $CONF_BATCH->{dirty};
    die $e                                 if $e;
    return $r;
}

# Record the change. Instant no-op when the content-history plugin is off, and
# eval-guarded there, so a git failure never fails the write.
#
# ATTRIBUTION. $auth_user is per-request ambient state, set by the dispatcher in
# the CGI process. A plugin hook runs as a SUBPROCESS (Plugins::_run_hook shells
# the plugin script), where that variable starts empty and the acting user
# arrives in the environment instead. Before SM255 this write did not commit, so
# an empty user was harmless; now it would author the commit as "unknown". Fall
# back to the environment the hook runner already sets.
sub _commit_conf {
    my ($message) = @_;
    require Lazysite::Git;
    my $who = ( defined $auth_user && length $auth_user )
        ? $auth_user
        : ( $ENV{LAZYSITE_ACTING_USER} // '' );
    Lazysite::Git::commit_paths( $DOCROOT, $who,
        ( $message // 'edit lazysite/lazysite.conf' ),
        'lazysite/lazysite.conf' );
    return;
}

# The single writer. $mutate receives the current content and returns the new
# content; returning undef means "nothing to do" and skips both write and
# commit. Returns ( ok, err ) in list context, ok in scalar - the contract the
# callers already expect.
sub _write_conf {
    my ( $mutate, $message ) = @_;
    my $conf_path = _conf_path_of();

    # Serialise the read-modify-write. The Services page fires every changed key
    # as its own config-set in parallel, so several processes reach this at once;
    # without the lock the second write drops the first (lost update).
    open my $lock, '>', "$conf_path.lock"
        or return wantarray ? ( 0, "Cannot lock lazysite.conf: $!" . _perm_hint() ) : 0;
    unless ( flock $lock, LOCK_EX ) {
        my $err = "$!";
        close $lock;
        return wantarray ? ( 0, "Cannot lock lazysite.conf: $err" ) : 0;
    }

    my $content = '';
    if ( -f $conf_path ) {
        unless ( open my $fh, '<:utf8', $conf_path ) {
            my $e = "$!";
            close $lock;
            return wantarray ? ( 0, "Cannot read lazysite.conf: $e" ) : 0;
        }
        else {
            $content = do { local $/; <$fh> };
            close $fh;
        }
    }

    my $new = $mutate->($content);
    unless ( defined $new ) { close $lock; return wantarray ? ( 1, '' ) : 1 }

    # Atomic: temp + rename, so a lock-free reader never sees a partial file.
    my ( $ok, $err ) = write_file_checked( $conf_path, $new );
    close $lock;    # releases the exclusive flock
    return wantarray ? ( 0, $err ) : 0 unless $ok;

    # Commit, or mark the batch dirty so its owner commits once at the end.
    if ($CONF_BATCH) { $CONF_BATCH->{dirty} = 1 }
    else             { _commit_conf($message) }
    return wantarray ? ( 1, '' ) : 1;
}

# Set (or add) one `key: value` line.
sub write_conf_key {
    my ( $key, $value, $message ) = @_;
    # An empty value is allowed (writes "key:" - used to CLEAR a key, e.g.
    # canonical_ip = auto-detect); the caller is the emptiness gate. The key
    # itself must be present and name-shaped.
    return 0 unless defined $key && length $key && defined $value;
    return 0 unless $key =~ /^[A-Za-z_][A-Za-z0-9_-]*$/;
    return _write_conf(
        sub {
            my ($c) = @_;
            if   ( $c =~ /^$key\s*:/m ) { $c =~ s/^$key\s*:.*$/$key: $value/m }
            else                        { $c =~ s/\n?$/\n/; $c .= "$key: $value\n" }
            return $c;
        },
        ( $message // "edit lazysite/lazysite.conf ($key)" ) );
}

# Replace the whole file. The domain verbs rewrite it wholesale (alias_hosts plus
# a set of alias.<host>.<key> lines), which a per-key setter cannot express.
sub write_conf_content {
    my ( $content, $message ) = @_;
    return 0 unless defined $content;
    return _write_conf( sub { return $content }, $message );
}

# Back-compat: the old private name, kept so existing callers and the
# content-history plugin (which imports it by name at runtime) keep working.
sub _write_conf_key { return write_conf_key(@_) }

1;
