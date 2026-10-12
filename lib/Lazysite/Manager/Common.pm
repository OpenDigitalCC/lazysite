package Lazysite::Manager::Common;

# Shared path / deny / write / respond helpers for the manager (SM079). The
# per-request ambient context ($DOCROOT, $action, $auth_user) is set by the
# dispatcher as package variables, so the handler bodies that use these helpers
# move verbatim. The deny list @BLOCKED_PATHS is owned here. SM944 S21: the
# whole request context is owned here too, fail-closed until the dispatcher
# sets it (see "the manager request context" below).

use strict;
use warnings;
use Cwd            qw(realpath);
use Errno          ();                  # %! (errno names) for the permission-failure hint
use File::Basename qw(dirname basename);
use Fcntl          qw(:flock);
use IPC::Open2     qw(open2);           # SM944 S22b: the users-tool client
use JSON::PP          qw(encode_json decode_json);
use Lazysite::Util qw(log_event);
use Lazysite::Private ();
use Exporter 'import';
use Lazysite::Paths ();
use Lazysite::Auth::Settings ();                  # SM944 S31: _display_names
use Lazysite::Auth::Acl      qw(_is_operator);    # SM944 S32: _operator

our @EXPORT_OK = qw(validate_path is_blocked_path write_file_checked respond _emit_json
    is_blocked_config is_blocked_upload_target upload_limits load_upload_limits _reset_upload_limits_cache
    _write_conf_key write_conf_key write_conf_content conf_batch path_out_of_scope outside_all_scopes no_scope_refusal _no_scope_refusal reserved_roots path_is_reserved
    caller_may_reach_domain request_domain_confined reachable_domains domain_reach_refusal
    caller_is_confined instance_wide_refusal
    served_artifact_refusal caller_may_reach_path form_pages form_bindings caller_may_reach_form form_reach_refusal
    page_form page_form_names page_form_or_none text_as_processor_reads form_bind_refusal form_bind_tree_refusal
    page_bytes_refusal invalid_utf8_offset
    caller_may_reach_table caller_may_reach_brief brief_reach_refusal
    carveout_requirement carveout_refusal path_leads_to_carveout
    raw_html_page_refusal page_parse_refusal page_parse_issues processor_path brief_write_refusal
    active_artifact_refusal refusal_detail refusal_status
    reset_request_context NO_REQUEST_CONTEXT users_api _users_tool_run _users_tool_path _tool_path _user_caps
    $action $auth_user $token_auth %token_caps @REQUEST_SCOPES $REQUEST_CONFINED $IS_OPERATOR $path $body
    %USER_CAPS $REQUEST_IP _request_ip _display_names _operator
    %params $JSON_BODY _json_body);

our $DOCROOT;    # set by the script

# SM293: this site's engine tree - beside the docroot once migrated,
# inside it before. Asked, never computed, so both layouts work on one
# code path and a site migrates by moving the directory.
sub _lz { return Lazysite::Paths::lazysite_dir($DOCROOT) }

# SM531 / SM852: is <base>.html a RENDER, or content? The processor renders
# <page>.md and <page>.url alike, so an .html beside either is a generated cache
# a sweep may drop. An .html with neither is a legacy static page (SM133) or an
# author's include partial (SM072) - content, never to be deleted by a cache
# sweep. One answer for every walk: Themes' sweeps asked it, and Files' nav-save
# sweep did not, so saving the navigation deleted every hand-written page.
sub render_source_exists {
    my ($base) = @_;
    return ( -f "$base.md" || -f "$base.url" ) ? 1 : 0;
}

# --- SM944 S21: the manager request context ----------------------------------
#
# The facts one manager-API request establishes about itself: who is asking
# ($auth_user), through which door ($token_auth, and the token's own grant in
# %token_caps), how far it reaches (@REQUEST_SCOPES, and $REQUEST_CONFINED,
# whether those scopes were resolved at all), whether it is the operator
# ($IS_OPERATOR, the memo behind _operator() below), and what it asked
# for ($action, $path, $body). S22b added %USER_CAPS, the per-account caps memo
# behind _user_caps below, which only the reset and _user_caps write; S31 added
# $REQUEST_IP, the request address's cache behind _request_ip, which only the
# reset and _request_ip write. S32 moved _operator here beside _user_caps: it is
# the one sub that fills $IS_OPERATOR, which the reset leaves 0 (not the
# operator) and the script clears to undef once it has authenticated a request.
# S33a added %params, the query string the script parses, and $JSON_BODY, the
# body memo that only _json_body (below) fills.
#
# OWNED HERE, WRITTEN BY ONE FILE. lazysite-manager-api.pl imports them in place
# of the file-scope `my` variables it used to declare, sets them as the request
# is authenticated and parsed, and an area module imports the ones it reads, so
# a handler moved out of the script reads the same facts unchanged. Nothing
# else assigns them; t/lint/217 holds that (ruled 2026-10-09).
#
# FAIL-CLOSED UNTIL SET. reset_request_context() is run when this module loads
# and by the script before its auth check, and it leaves a request that is
# nobody, holds no capability, is a token client (so never the cookie operator)
# and is confined to a scope that contains no path. An empty @REQUEST_SCOPES
# means UNCONFINED to the content readers (outside_all_scopes, the script's
# path checks) - for a token's domain writes it means no domain (SM975) - so
# empty would be the wrong default: an entry point that loads a
# handler and never establishes a request - the daemon, the MCP server, WebDAV,
# a test - would hand it the sysop's reach. The scope is NO_REQUEST_CONTEXT, a
# string with a NUL in it: no path, host or content root can contain one, so
# every boundary-safe scope check finds every path outside it.
#
# $action and $auth_user were here before S21, as the log attribution, and
# other entry points set them (lazysite-mcp.pl's action, the users CLI's
# acting user, three modules' write bridges - the exceptions lint 217 names).
# Their default is the empty string they always had.
sub NO_REQUEST_CONTEXT { return "\0no request context" } # a sub: lint 02 refuses `use constant`
our ( $action, $auth_user, $token_auth, %token_caps, @REQUEST_SCOPES, $REQUEST_CONFINED,
    $IS_OPERATOR, $path, $body, %USER_CAPS, $REQUEST_IP, %params, $JSON_BODY );

sub reset_request_context {
    $action     = '';                                          # no action
    $auth_user  = '';                                          # nobody
    $token_auth = 1;                                           # never the cookie operator
    %token_caps = ( dav_scopes => [ NO_REQUEST_CONTEXT() ] );  # no capability, no reach
    @REQUEST_SCOPES   = ( NO_REQUEST_CONTEXT() );              # confined to nothing
    $REQUEST_CONFINED = 1;
    $IS_OPERATOR      = 0;
    $path             = undef;
    $body             = '';
    %USER_CAPS        = ();                          # no account's caps remembered
    $REQUEST_IP       = undef;                       # no visitor's address remembered
    %params           = ();                          # no request's parameters
    $JSON_BODY        = undef;                       # no request's body remembered
    return;
}
reset_request_context();

# --- SM944 S31: the request address -------------------------------------------
#
# Moved out of lazysite-manager-api.pl (ruled 2026-10-10, "(c) request IP into
# Common"); the script and the audit trail's switch call it. Its cache was a `my`
# in a bare block of the script, new with every run of it; here it lives as long
# as the process that loaded Common, so it joined the request context above as
# $REQUEST_IP: emptied by reset_request_context(), which the script runs before
# its auth check, and filled only by _request_ip (t/lint/217). Without the reset
# a pooled worker would record one request's visitor against the next. It reads
# the conf under $LAZYSITE_DIR, which the script sets to its own.
our $LAZYSITE_DIR;    # set by the script

# SM929: THE request address for this request - the visitor, not the front proxy.
# One reader, cached, because everything below asks the same question about one
# request. Behind a front proxy REMOTE_ADDR is a single constant for every visitor
# a site will ever have, so an address column held the infrastructure's identity
# and anything keyed on it shared one bucket with the world.
sub _request_ip {
    return $REQUEST_IP if defined $REQUEST_IP;
    require Lazysite::Util;
    $REQUEST_IP = Lazysite::Util::request_address(
        Lazysite::Util::trusted_proxy_spec($LAZYSITE_DIR) );
    return $REQUEST_IP;
}

# --- SM944 S33a: the request's parameters and its body ------------------------
#
# Ruled 2026-10-11 ("Yes, S33a then groups"). %params, the request's query
# string decoded, and $JSON_BODY, the memo behind _json_body, were file-scope
# `my` variables of lazysite-manager-api.pl, new with every run of it, and
# read by the dispatch branches S33 moves into the area modules. They joined the
# request context above under their script names: emptied by
# reset_request_context(), which the script runs before its auth check; %params
# written only by the script, where it parses the query string, and $JSON_BODY
# filled only by _json_body, which moved here unchanged with its comment
# (t/lint/217). Without the reset a pooled worker would hand one request's
# parameters or body to the next.

# SM516 MA-2 / MO-2: ONE decode of the request body per request.
#
# Forty-odd dispatch branches and the audit block each wrote
# `eval { decode_json($body) } // {}`, so an ordinary POST decoded its own body
# up to five times before it was answered. $body is read once, above, and never
# reassigned, so the answer cannot change between calls.
#
# The shape is preserved rather than improved: a body that is empty, or is not
# JSON, still yields {} - which is exactly what `// {}` handed every caller -
# and a body that decodes to a non-hash is still handed on as it was.
sub _json_body {
    return $JSON_BODY //= ( eval { decode_json($body) } // {} );
}

# --- SM944 S22b: the users-tool client and the caps memo --------------------
#
# Moved unchanged out of lazysite-manager-api.pl (ruled 2026-10-09). The script
# imports them; S23's handlers call them from their own modules.
#
# %USER_CAPS, the memo behind _user_caps (SM516 MO-1), is declared with the
# request context above and emptied by reset_request_context(), which the script
# runs before its auth check. It was a file-scope `my` of the script, new with
# every run of it; here it lives as long as the process that loaded Common, so
# without the reset a pooled worker would answer one request's caps question
# from an earlier request's account store. Filled only by _user_caps
# (t/lint/217).

# Resolve a shipped tool across install layouts: the cgi-bin sibling in
# production, the repo root in tests, the docroot's parent for a packaged
# install. The named environment variable wins, so a test or an operator can
# point at one directly.
sub _tool_path {
    my ( $env_key, $rel ) = @_;
    for my $c (
        $ENV{$env_key},
        dirname($0) . "/../$rel",
        dirname($0) . "/$rel",
        "$DOCROOT/../$rel",
    ) {
        return $c if defined $c && -f $c;
    }
    return undef;
}

# The user-management tool. LAZYSITE_USERS_TOOL wins.
sub _users_tool_path { return _tool_path( 'LAZYSITE_USERS_TOOL', 'tools/lazysite-users.pl' ) }

# One request against tools/lazysite-users.pl --api, decoded. The three
# failure sentences are PASSED IN rather than unified: both callers surface
# their own wording to the client, so folding them would change what a caller
# reads on a failure - a behaviour change, not a tidy-up. $cannot_run is a
# sprintf template so the caller that reports $@ still can.
sub _users_tool_run {
    my ( $payload, $unavailable, $cannot_run, $invalid ) = @_;
    my $script = _users_tool_path();
    return { ok => 0, error => $unavailable } unless $script;
    my ( $out, $in );
    local $SIG{PIPE} = 'IGNORE';    # SM959: a child that exits early must not kill us
    my $pid = eval { open2( $out, $in, $^X, $script, '--api', '--docroot', $DOCROOT ) };
    return { ok => 0, error => sprintf( $cannot_run, $@ ) } unless $pid;
    print $in encode_json($payload);
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    return eval { decode_json( $resp // '{}' ) } // { ok => 0, error => $invalid };
}

# Run a request against tools/lazysite-users.pl --api and return the
# decoded response (used by the token front-path's verify-credential).
sub users_api {
    my ($payload) = @_;
    return _users_tool_run( $payload, 'user management unavailable',
        'cannot run user management', 'invalid response' );
}

# SEC-2026-07 (H1): the acting cookie user's full effective capability hash, for
# the cookie-side authorization gate (the token path uses %token_caps). Every
# cookie-side capability question is one read of this hash - SM141's session and
# key gate, the notifications bell, the audit scope and action_users' own gate.
sub _user_caps {
    my ($user) = @_;
    return {} unless defined $user && length $user;

    # SM516 MO-1: MEMOISED PER USER, PER REQUEST. Every call forks the users
    # tool and reads the account store, and an ordinary cookie request asks
    # twice - the gate ahead of dispatch, then the action's own gate - while
    # whoami asks three times. Nothing writes the account store before a read
    # of it in the same request: action_users' own gate runs before its write,
    # and every other reader is a gate that runs before dispatch. So a second
    # ask inside one request cannot return a different answer.
    #
    # Callers only READ the hash. Handing back the same reference each time is
    # what makes this a memo rather than a copy, and carveout_refusal - the one
    # place it is passed on - reads it too.
    return $USER_CAPS{$user}
        //= ( users_api( { action => 'settings-get', username => $user } ) || {} )->{settings}
        || {};
}

# SM516 MO-3: _is_operator() re-reads the group settings store on every call,
# and three gates ask it. Its inputs cannot change between them within one
# request: the cookie gate runs ahead of dispatch, and action_users' two calls
# both run before it writes anything through the users tool.
sub _operator {
    return $IS_OPERATOR //= ( _is_operator() ? 1 : 0 );
}

# SM778: THE NAMES THAT GO WITH THE LOGINS THIS RESPONSE ALREADY CARRIES.
#
# Reported from familyhq.explore: the engine hands back logins and holds the
# display names, and gives a site no way to join the two - so the site mirrored
# the names into its own table and the mirror drifted until every byline read
# as a bare login.
#
# The shape itself lives with the resolver, in Lazysite::Auth::Settings, so
# that the manager API, the ACL reader and the MCP twin add the same two keys
# rather than three hand-kept copies of them (SM662 is the general form).
sub _display_names { return Lazysite::Auth::Settings::display_names_block(@_) }

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
    return { ok => 0, kind => 'invalid-path', error => 'No path was given. Every file action needs a docroot-relative path such as pages/about.md.',
        audit_detail => 'invalid-path: no path given - send a docroot-relative path' }
        unless $rel_path;

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
    return { ok => 0, kind => 'invalid-path',
        error => "'$rel_path' is not a valid path: it contains a '..' segment. Paths are docroot-relative and forward (pages/about.md), never climbing.",
        audit_detail => refusal_detail( 'invalid-path', "'$rel_path' contains a .. segment", 'send a docroot-relative forward path' ) }
        if $rel_path =~ m{(?:\A|/)\.\.(?:/|\z)};

    # SM850: A `lazysite/...` PATH IS IN THE ENGINE TREE, WHEREVER THAT IS. The
    # carve-outs a partner reaches by path - nav.conf, the layouts and themes,
    # brands, form submissions - are named `lazysite/...`, and joined to the
    # docroot they were looked for inside it. On a site whose tree moved beside
    # the docroot (SM293) a save made a stray engine tree in the served tree and
    # answered ok, and a read said not found. Confined to the engine tree by the
    # same strict, boundary-safe test as the two branches below, in its own
    # tree; the blocklist still rules on the rel, which is unchanged.
    return _validate_engine_path($rel_path) if $rel_path =~ m{\Alazysite(?:/|\z)};

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
        return { ok => 0, kind => 'invalid-path',
            error => "'$rel_path' is inside a protected section but this site has no private store to hold it - run: lazysite check --fix",
            audit_detail => refusal_detail( 'invalid-path', "'$rel_path' is protected and the private store is missing", 'lazysite check --fix' ) }
            unless defined $proot && defined $pfull;

        # SM510: the same nearest-existing-ancestor walk as the docroot
        # branch, for the same reason - a deep new path inside a gated
        # section is as ordinary as a shallow one.
        my $panchor = $pfull;
        $panchor = dirname($panchor) until -e $panchor;
        my $preal = realpath($panchor);
        return { ok => 0, kind => 'invalid-path',
            error => "'$rel_path' resolves outside the site (through a symlink or a mount) and is refused. Paths must stay inside the site's own tree.",
            audit_detail => refusal_detail( 'invalid-path', "'$rel_path' resolves outside the site", 'use a path inside the site tree' ) }
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

# SM850: validate_path for a rel under lazysite/ - the engine tree, inside the
# docroot or beside it. The nearest-existing-ancestor walk and the containment
# test are the docroot branch's, run against the engine tree's own root; rel is
# rebuilt from the resolved path so a symlink cannot mint a second key.
sub _validate_engine_path {
    my ($rel_path) = @_;
    my $lz         = _lz();
    my $lzreal     = defined $lz ? realpath($lz) : undef;
    return { ok => 0, kind => 'invalid-path',
        error => "'$rel_path' is in the engine tree, and this site has none - run: lazysite check --fix",
        audit_detail => refusal_detail( 'invalid-path', 'no engine tree', 'lazysite check --fix' ) }
        unless defined $lzreal && -d $lzreal;

    ( my $tail = $rel_path ) =~ s{\Alazysite/*}{};
    my $full   = length $tail ? "$lz/$tail" : $lz;
    my $anchor = $full;
    $anchor = dirname($anchor) until -e $anchor;
    my $real = realpath($anchor);
    return { ok => 0, kind => 'invalid-path',
        error => "'$rel_path' resolves outside the site (through a symlink or a mount) and is refused. Paths must stay inside the site's own tree.",
        audit_detail => refusal_detail( 'invalid-path', "'$rel_path' resolves outside the site", 'use a path inside the site tree' ) }
        unless $real && ( $real eq $lzreal || index( $real, "$lzreal/" ) == 0 );

    my $canon = ( -e $full ) ? $real : $real . substr( $full, length($anchor) );
    $canon =~ s{(?<=.)/+\z}{};
    ( my $rest = $canon ) =~ s{\A\Q$lzreal\E/?}{};
    my $rel = length $rest ? "lazysite/$rest" : 'lazysite';
    return { ok => 1, full => $canon, rel => $rel, store => 'engine', public_full => $canon };
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

# SM661 named every argument that carries a content path here, once, for every
# MCP tool (@PATH_ARGS: path to from slug old new). SM976 Q15f (ruled
# 2026-10-09, "Fix: per-tool path args") moved the fact onto each tool
# (`path_args` in lazysite-mcp.pl's %TOOLS): one list for every tool made
# replace_text's `old` and `new` - text - paths. t/lint/91 holds it.

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

# SM975: the refusal a TOKEN naming no scope gets from a domain write. Empty is
# unconfined above, which is what a CONTENT path check means by it (an unbound
# WebDAV or MCP account reaches the whole primary site). For a domain it is the
# opposite: a token reaches only the domains its scope names, and none when it
# names none (ruled 2026-10-09). Each surface decides who is a token; the words
# are here so the manager API, the remap module and MCP say the same thing.
sub no_scope_refusal {
    return { ok => 0, kind => 'forbidden',
        error => 'A token reaches only the domains its scope names, and this grant '
            . 'names no dav_scope, so it reaches no domain. An operator gives it one '
            . "by naming the token account's group in that domain's allowed_groups "
            . '(Domains page).' };
}

# SM975: NO SCOPE = NO DOMAIN, for every domain write a token can make.
#
# A token reaches only the domains its scope names, and a token naming no scope
# reaches none (ruled 2026-10-09). domain-set, remap-save and site-backup-apply
# read an empty scope as unconfined, and domain-add, domain-alias-add and
# domain-remove did not ask, so a manage_domains token that nobody had scoped
# wrote every domain on the instance, and remap-save also accepted hosts the
# instance does not serve. The cookie session is the sysop and stays exempt,
# as in _root_outside_grant. The answer for a token with a scope is unchanged
# here; each action checks that scope itself.
sub _no_scope_refusal {
    return undef unless $token_auth && !@REQUEST_SCOPES;
    return Lazysite::Manager::Common::no_scope_refusal();
}

# SM976: ONE RULE FOR DOMAIN REACH. A domain-confined caller reaches only its own
# domains, on every surface; the unconfined operator reaches all of them (ruled
# 2026-10-09). Every action addressed by a host or a content root asks this, and
# t/lint/218 holds that.
#
#   caller_may_reach_domain( host => $h )    a configured domain, '' or
#                                            '(default)' the primary
#   caller_may_reach_domain( root => $r )    a content root, e.g. a new domain's
#
# WHO. By default the manager request: the cookie operator is unconfined, and so
# is a cookie manager whose groups bind no domain (an empty scope on the cookie
# channel is no confinement, as it is for its content paths); a token is always
# confined, and so is a cookie manager with a scope. MCP and WebDAV pass
# `scopes => [...]`: every caller there is a grant, so it is confined.
#
# THE ANSWER for a confined caller:
#   - a host the instance does not serve: no;
#   - a domain with a content root of its own: yes when that root lies inside
#     one of its scopes, no otherwise, and no when it names none (SM975);
#   - the PRIMARY, and a domain with no root of its own (it serves the primary's
#     content): the content-path rule, which SM975 left as documented - an
#     unbound account reaches the primary site, a scoped one does not (ruled
#     2026-10-09, R3 "Keep for primary"; any other domain needs a scope).
# Actions that refuse a token naming no scope outright (the domain writes and
# the site packages, SM975/SM578) keep that refusal ahead of this one.
sub caller_may_reach_domain {
    my (%a) = @_;
    my $confined = exists $a{scopes} ? 1 : request_domain_confined();
    return 1 unless $confined;
    my @scopes = exists $a{scopes}
        ? grep { defined && length } @{ $a{scopes} || [] }
        : @REQUEST_SCOPES;
    my $root = exists $a{root} ? _clean_root( $a{root} ) : _domain_root_of( $a{host} );
    return 0                   unless defined $root;   # not a domain this instance serves
    return ( @scopes ? 0 : 1 ) unless length $root;    # the primary's content
    return 0                   unless @scopes;         # SM975: no scope, no domain
    return outside_all_scopes( \@scopes, $root ) ? 0 : 1;
}

# Is the manager request a domain-confined caller? The token channel always is;
# the cookie channel is when the request resolved a scope for a non-operator.
sub request_domain_confined {
    return 1 if $token_auth;
    return ( $REQUEST_CONFINED && @REQUEST_SCOPES ) ? 1 : 0;
}

sub _clean_root {
    my ($r) = @_;
    $r //= '';
    $r =~ s{/+}{/}g;
    $r =~ s{(?:^|/)\.(?=/|$)}{/}g;
    $r =~ s{/+}{/}g;
    $r =~ s{^/+|/+$}{}g;
    return $r;
}

# The content root a host serves from: '' for the primary (by '', '(default)'
# or its site_url host) and for a domain with no root of its own, undef for a
# host the instance does not serve.
sub _domain_root_of {
    my ($host) = @_;
    $host = lc( $host // '' );
    $host =~ s/^\s+|\s+$//g;
    return '' if $host eq '' || $host eq '(default)';
    require Lazysite::Manager::Domains;
    no warnings 'once';
    local $Lazysite::Manager::Domains::DOCROOT
        = $Lazysite::Manager::Domains::DOCROOT // $DOCROOT // $ENV{DOCUMENT_ROOT};
    my $list = eval { Lazysite::Manager::Domains::domains_list() };
    return undef unless ref $list eq 'HASH' && $list->{ok};
    my $prim_url_host;
    for my $d ( @{ $list->{domains} || [] } ) {
        if ( $d->{is_primary} ) {
            ($prim_url_host) = ( $d->{site_url} // '' ) =~ m{^https?://([^/:?#]+)}i;
            next;
        }
        return _clean_root( $d->{content_root} ) if lc( $d->{host} // '' ) eq $host;
    }
    return '' if defined $prim_url_host && lc($prim_url_host) eq $host;
    return undef;
}

# The configured hosts this caller reaches, in list order: '(default)' for the
# primary. Takes the same `scopes` override as the predicate.
sub reachable_domains {
    my (%who) = @_;
    require Lazysite::Manager::Domains;
    no warnings 'once';
    local $Lazysite::Manager::Domains::DOCROOT
        = $Lazysite::Manager::Domains::DOCROOT // $DOCROOT // $ENV{DOCUMENT_ROOT};
    my $list = eval { Lazysite::Manager::Domains::domains_list() };
    return () unless ref $list eq 'HASH' && $list->{ok};
    return map { $_->{host} }
        grep { caller_may_reach_domain( %who, host => $_->{host} ) } @{ $list->{domains} || [] };
}

# The refusal for a domain this caller may not reach, or undef when it may. It
# names the caller's scope and the domains it does reach, so the next call can
# be the right one; `domains` carries the same list for a client to pick from.
sub domain_reach_refusal {
    my (%a) = @_;
    my %who = exists $a{scopes} ? ( scopes => $a{scopes} ) : ();
    return undef if caller_may_reach_domain(%a);
    my @scopes = exists $a{scopes} ? @{ $a{scopes} || [] } : @REQUEST_SCOPES;
    my $what   = exists $a{root}
        ? ( length _clean_root( $a{root} )
        ? "the content root '" . _clean_root( $a{root} ) . "'"
        : "the primary site's content (no content root of its own)" )
        : do {
        my $h = lc( $a{host} // '' );
        ( $h eq '' || $h eq '(default)' ) ? 'the primary site' : "the domain '$h'";
        };
    my @mine  = reachable_domains(%who);
    my $scope = @scopes
        ? 'its scope (' . join( ', ', map { ( my $x = $_ ) =~ s{^/+|/+$}{}g; "$x/" } @scopes ) . ')'
        : 'no scope';
    return { ok => 0, kind => 'forbidden', domains => \@mine,
        error => "You cannot reach $what. A domain-confined caller reaches only the "
            . "domains whose content lies inside $scope"
            . ( @mine ? ': ' . join( ', ', @mine ) . '.' : ', and that is none.' ) };
}

# SM976 R1: CONFINED MEANS NO INSTANCE-WIDE WRITE. A caller whose grant names a
# scope acts on its own domains only, through the actions addressed to a host;
# it changes no setting, registry or shared library the whole instance reads
# (ruled 2026-10-09, "Confined = no instance-wide"). The closed list of those
# actions is `instance_wide => 1` in Lazysite::ControlApi::Actions, and
# t/lint/218 holds every mutating action to it.
#
# WHO IS CONFINED HERE. The caller_may_reach_domain notion, read one way: a
# caller on a confined channel (a token, an MCP grant, a WebDAV account, a
# cookie manager whose scope was resolved) whose scope list is NOT EMPTY. Scopes
# are the content roots of the domains its groups are named on, or SM165's
# deny-all for a locked account, so a non-empty scope binds it to some domains
# and never to the primary - the predicate already refuses such a caller the
# primary site. An UNBOUND token, grant or account reaches the primary by the
# content-path rule (R3, "keep for primary"); the instance's settings are the
# primary's, so it keeps them, as do the operator and an unbound cookie manager
# (R2). Takes the predicate's `scopes => [...]` override for MCP and WebDAV.
sub caller_is_confined {
    my (%a) = @_;
    my $confined = exists $a{scopes} ? 1 : request_domain_confined();
    return 0 unless $confined;
    my @scopes = grep { defined && length } ( exists $a{scopes} ? @{ $a{scopes} || [] } : @REQUEST_SCOPES );
    return @scopes ? 1 : 0;
}

# The refusal for an instance-wide write by a confined caller, or undef. It
# names what was asked, why, and the domains the caller does act on.
sub instance_wide_refusal {
    my (%a) = @_;
    my %who = exists $a{scopes} ? ( scopes => $a{scopes} ) : ();
    return undef unless caller_is_confined(%who);
    my $what = $a{action} // 'this action';
    my @mine = reachable_domains(%who);
    return { ok => 0, kind => 'forbidden', instance_wide => 1, domains => \@mine,
        error => "'$what' changes the whole instance, and a domain-confined caller "
            . 'changes no instance-wide setting: it acts on its own domains only'
            . ( @mine ? ' (' . join( ', ', @mine ) . ')' : '' )
            . ', through the actions addressed to a host. An operator makes '
            . 'instance-wide changes.' };
}

# The `scopes` override, passed on unchanged: present for MCP and WebDAV, absent
# for the manager request.
sub _who { my (%a) = @_; return exists $a{scopes} ? ( scopes => $a{scopes} ) : () }

# Is the caller confined at all, in caller_may_reach_domain's sense? Every grant
# passed as `scopes` is; on the manager request, a token always and a cookie
# manager with a scope.
sub _confined_who { my (%who) = @_; return exists $who{scopes} ? 1 : request_domain_confined() }

# SM976 F1 (ruled 2026-10-09, "Yes, any served artifact"): A THEME OR LAYOUT A
# SITE SERVES IS THAT SITE'S. A domain-confined caller writes a theme or layout
# only if no site serves it, or only domains inside its scope do. SM749's
# reasoning, carried from the instance's active pair to every pair the primary
# or a domain serves: a grant scoped to one domain wrote into the theme another
# domain is bound to (Q15c), because the active-theme rule protects only the
# instance's own.
#
# Who serves it: Domains::domain_usage, the effective layout and theme of the
# primary and of every configured host - so a domain that inherits the primary's
# theme serves it too, and the primary is reached as caller_may_reach_domain
# says (an unbound grant does, a scoped one does not). A theme path is served by
# the sites using that theme under that layout; any other path under a layout
# (its template, its assets, its themes/ folder) by every site using the layout.
# When the usage cannot be read, nothing is known to be unused: refused.
#
# The operator and an unbound cookie manager are not confined and are not asked;
# SM749's rule (active_artifact_refusal) still holds the instance's active pair
# for everyone. Pure apart from the domain configuration it reads, and shaped as
# the other content-write rules (error, or error and audit detail), so the choke
# point and the WebDAV stack share it (t/lint/114, t/lint/218).
sub served_artifact_refusal {
    my ( $rel, %who ) = @_;
    return unless defined $rel;
    ( my $r = $rel ) =~ s{^/+}{};
    my ( $layout, $rest ) = $r =~ m{^lazysite/layouts/([^/]+)(?:/(.*))?$};
    return unless defined $layout;
    my %by = _who(%who);
    return unless _confined_who(%by);
    my ($theme) = ( $rest // '' ) =~ m{^themes/([^/]+)};

    require Lazysite::Manager::Domains;
    no warnings 'once';
    local $Lazysite::Manager::Domains::DOCROOT
        = $Lazysite::Manager::Domains::DOCROOT // $DOCROOT // $ENV{DOCUMENT_ROOT};
    my $use = eval { Lazysite::Manager::Domains::domain_usage() };
    my @hosts;
    my $known = ref $use eq 'HASH';
    if ($known) {
        my $list = defined $theme ? $use->{themes}{"$layout\0$theme"} : $use->{layouts}{$layout};
        @hosts = map { $_ eq '(default)' ? '' : $_ } @{ $list || [] };
    }
    return if $known && !grep { !caller_may_reach_domain( %by, host => $_ ) } @hosts;

    my $what = defined $theme ? "the theme '$theme' (layout '$layout')" : "the layout '$layout'";
    my @mine = grep { $_ ne '(default)' } reachable_domains(%by);
    my $how  = defined $theme
        ? 'To change it for your own domain: copy it (copy_theme over MCP, theme-copy on the '
        . 'control API), edit the copy, then bind the copy to your domain (activate_theme or '
        . 'theme-activate with host).'
        : 'Edit a layout no other site serves, then bind it to your domain (activate_layout or '
        . 'layout-activate with host).';
    return _refusal(
        "$what is served by a site you do not reach. A domain-confined caller writes only a "
            . 'theme or layout that no site serves, or that only its own domains serve'
            . ( @mine ? ' (' . join( ', ', @mine ) . ')' : '' ) . ". $how",
        'served-artifact-refused',
        "$what is served by a site outside the caller's domains",
        defined $theme ? 'copy it, edit the copy, then activate the copy with host'
        : 'edit a layout no other site serves, then activate it with host'
    );
}

# SM976 F2: is a CONTENT PATH inside the caller's scope? The content-path rule
# the scope checks have always applied, as one predicate the form and brief
# rules can ask: an unconfined caller, and a grant naming no scope (R3, "keep
# for primary": its whoami says allow: /), reach every content path; a scoped
# one reaches the paths inside one of its scopes. The engine tree (lazysite/)
# and the site root lie inside no scope.
sub caller_may_reach_path {
    my ( $rel, %who ) = @_;
    my %by = _who(%who);
    return 1 unless _confined_who(%by);
    my @scopes = exists $by{scopes}
        ? grep { defined && length } @{ $by{scopes} || [] }
        : @REQUEST_SCOPES;
    return 1 unless @scopes;
    # Asked of the path as the caller sent it, which the action resolves later:
    # a `..` segment could leave the scope after this check passed, so it is
    # inside none.
    return 0 if ( $rel // '' ) =~ m{(?:\A|/)\.\.(?:/|\z)};
    my $p = _clean_root($rel);
    return 0 if $p eq '' || $p =~ m{^lazysite(?:/|\z)};
    return outside_all_scopes( \@scopes, $p ) ? 0 : 1;
}

# SM976 F2: the pages that bind a form - every Markdown page, public or in the
# private store (SM286), whose front matter names it (`form: NAME`, the key the
# processor renders the form from). Returned as docroot-relative paths.
sub form_pages {
    my ($name) = @_;
    return () unless defined $name && length $name;
    return @{ form_bindings()->{ lc $name } || [] };
}

# Every form's binding pages in one walk: { lc(form) => [ pages, sorted ] }.
sub form_bindings {
    my $doc = ( defined $DOCROOT && length $DOCROOT ) ? $DOCROOT : ( $ENV{DOCUMENT_ROOT} // '' );
    return {} unless length $doc;
    require File::Find;
    require Lazysite::Private;
    no warnings 'once';    # File::Find::prune is the module's, set from the callback
    my %pages;
    for my $base ( grep { defined && -d } $doc, Lazysite::Private::private_root($doc) ) {
        File::Find::find(
            { no_chdir => 1,
                wanted => sub {
                    my $f = $File::Find::name;
                    ( my $rel = $f ) =~ s{\A\Q$base\E/?}{};
                    if ( -d $f ) {
                        $File::Find::prune = 1
                            if $rel =~ m{(?:\A|/)\.}
                            || $rel =~ m{\A(?:lazysite|cgi-bin|manager)(?:/|\z)};
                        return;
                    }
                    return unless $rel =~ /\.md\z/;
                    # SM976 Q15f: the whole page, read as the processor reads it
                    # (read_file), and its form as the processor renders it.
                    # Q15h: a page whose reading dies binds nothing, logged, so
                    # one such page cannot stop the walk.
                    my $name = page_form_or_none( _read_as_processor($f), $rel );
                    return unless defined $name;
                    $pages{ lc $name }{$rel} = 1;
                },
            },
            $base
        );
    }
    return { map { $_ => [ sort keys %{ $pages{$_} } ] } keys %pages };
}

# A file's text as the processor's read_file holds it: the whole file through
# the :utf8 layer, so its front matter is matched with the same character
# semantics. undef when it cannot be read.
sub _read_as_processor {
    my ($abs) = @_;
    open my $fh, '<:utf8', $abs or return undef;
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t;
}

# Bytes about to be written raw (an upload, a binary save), as the processor
# will read them back: decoded as UTF-8 when they are UTF-8. Malformed bytes
# are left as they are.
sub text_as_processor_reads {
    my ($bytes) = @_;
    return $bytes unless defined $bytes && !utf8::is_utf8($bytes);
    my $t = $bytes;
    utf8::decode($t);
    return $t;
}

# SM976 Q15h (ruled 2026-10-09, "Refuse + walker skips"): A PAGE WRITTEN AS RAW
# BYTES IS VALID UTF-8. The processor reads a page through a lax :utf8 layer:
# on bytes that are not UTF-8 its parse dies (the page renders nothing) or
# reads a different front matter than text_as_processor_reads gives the write
# rule - a grant saved such bytes, the rule read no form, and the processor
# rendered the primary's form on the page (tmp/q15g-malformed-hijack-probe.out).
# So a .md page arriving as raw bytes - action_save_binary (MCP upload_file),
# the multipart upload, WebDAV PUT, a site package's content - is refused,
# for every caller, unless its bytes are valid UTF-8 (RFC 3629: no overlong
# forms, no surrogates, nothing past U+10FFFF). A text write cannot produce
# such a page: it is encoded on the way out.
sub page_bytes_refusal {
    my ( $rel, $bytes ) = @_;
    return unless defined $rel && defined $bytes;
    ( my $r = $rel ) =~ s{^/+}{};
    return unless $r =~ /\.md\z/;
    my $at = invalid_utf8_offset($bytes);
    return unless defined $at;
    return _refusal(
        "The page '$r' is not valid UTF-8 (the first invalid byte is at offset $at), so it was "
            . 'not written. lazysite reads every page as UTF-8, and a page that is not renders '
            . 'nothing or is read with front matter other than what its checks saw. To fix it, '
            . 'save the file as UTF-8 (your editor\'s encoding setting, or iconv -t UTF-8) and '
            . 'write it again.',
        'page-encoding-refused',
        "the page '$r' is not valid UTF-8 (first invalid byte at offset $at)",
        'save it as UTF-8 and write it again'
    );
}

# SM976 Q15j (ruled 2026-10-10, "Fix both" (a)): A PAGE THAT IS NOT UTF-8 IS
# ANSWERED AS A PAGE THAT CANNOT BE READ. Such a page reaches the disk by a door
# that writes no caller's bytes (git, SSH, a restore). Read through the lax
# :utf8 layer, its malformed bytes made the JSON encoder die, so MCP read_page,
# read_file, view_version, read_brief and preview_page answered with no body
# at all, and validate_page and create_form with a bare "Tool error"
# (tmp/q15j-single-page-probe.before.out). The text is judged as it was read:
# a string the :utf8 layer read holds the file's own bytes, which utf8::encode
# hands back unchanged, so the offset is the file's. $what names what was read
# ("version 1a2b3c4 of"), $remedy replaces the default way to fix it, and
# $remedy_short its line in the audit detail.
sub page_read_refusal {
    my ( $rel, $text, %o ) = @_;
    return unless defined $rel && defined $text;
    my $b = $text;
    utf8::encode($b) if utf8::is_utf8($b);
    my $at = invalid_utf8_offset($b);
    return unless defined $at;
    ( my $r = $rel ) =~ s{^/+}{};
    my $noun   = $r =~ /\.md\z/ ? 'page' : 'file';
    my $what   = defined $o{what} ? "$o{what} the $noun '$r'" : "The $noun '$r'";
    my $remedy = $o{remedy}
        // 'save the file as UTF-8 (your editor\'s encoding setting, or iconv -t UTF-8) and write it '
        . 'again - upload_file or WebDAV replaces it whole';
    return _refusal(
        "$what is not valid UTF-8 (the first invalid byte is at offset $at), so it cannot be read "
            . 'as text. lazysite reads every page as UTF-8, and the processor renders nothing for '
            . "a page that is not. To fix it, $remedy.",
        'page-encoding-refused',
        lcfirst("$what is not valid UTF-8 (first invalid byte at offset $at)"),
        $o{remedy_short} // 'save it as UTF-8 and write it again'
    );
}

# The offset of the first byte that is not part of valid UTF-8, or undef when
# all of it is. A character string is judged as the bytes it will be written
# as: one that holds only characters below 256 is written byte for byte.
sub invalid_utf8_offset {
    my ($bytes) = @_;
    return undef unless defined $bytes;
    my $b = $bytes;
    return undef if utf8::is_utf8($b) && !utf8::downgrade( $b, 1 ); # wide: written as UTF-8
    require Encode;
    my $rest = $b;
    Encode::decode( 'UTF-8', $rest, Encode::FB_QUIET() ); # leaves what it could not decode
    return length $rest ? length($b) - length($rest) : undef;
}

# SM976 Q15h (ruled 2026-10-09, "Refuse + walker skips"): the form a page binds,
# where A PAGE WHOSE READING DIES BINDS NOTHING, and the death is logged. A page
# that is not valid UTF-8 can reach the disk by a door that writes no bytes of
# a caller's (git, SSH, a backup restore); page_form, the processor's reading,
# dies on many such pages, as the processor does (and renders nothing for
# them). One such page made form_bindings die, and with it every form verb and
# every write of a page binding a form (tmp/q15g-walker-die-probe.out).
sub page_form_or_none {
    my ( $text, $rel ) = @_;
    my $form = eval { page_form($text) };
    return $form unless $@;
    ( my $why = $@ ) =~ s/\s+at \S+ line \d+.*//s;
    log_event( 'WARN', 'form-rule', 'a page whose front matter cannot be read binds no form',
        page => ( $rel // '(unnamed)' ), error => $why );
    return undef;
}

# SM976 Q15f (ruled 2026-10-09, "One reading, processor's"): THE FORM A PAGE
# BINDS, as the processor renders it - so "which form a page binds" has one
# answer everywhere: the form rule's walker (form_bindings), the write rule
# (form_bind_refusal, through page_form_names), create_form and the validators.
#
# A MARKED COPY of the processor's reading: lazysite-processor/front-matter.pm,
# parse_yaml_front_matter - the front matter block, the scalar `key: value`
# loop (the last column-0 `form:` wins, and its `\s*` reads a value on the next
# line), strip_tt_directives, one pair of quotes, then the form sanitiser. The
# render path loads no modules (ADR 0001), so it cannot call this; t/lint/219
# runs both over the same texts and fails when they differ.
#
# $text is the page as the processor holds it after read_file: characters. The
# copy matches with character semantics, as the processor's :utf8 read gives
# it (a byte string is upgraded, never decoded, here: bytes about to be written
# raw go through text_as_processor_reads first). Returns the form's name, case
# as written, or undef.
sub page_form {
    my ($text) = @_;
    return undef unless defined $text;
    my $t = $text;
    utf8::upgrade($t);
    return undef unless $t =~ /\A---\s*\n(.*?)\n---\s*\n/s;
    my ( $yaml, $form ) = ($1);
    while ( $yaml =~ /^(\w+)\s*:\s*([^\n]+)$/mg ) {
        next unless $1 eq 'form';
        my $v = $2;
        $v =~ s/\[%//g;
        $v =~ s/%\]//g;
        $v =~ s/\s+\z//;
        $v =~ s/\A"(.*)"\z/$1/s or $v =~ s/\A'(.*)'\z/$1/s;
        $form = $v;
    }
    return undef unless defined $form;
    $form =~ s/[^a-zA-Z0-9_-]//g;
    return length $form ? $form : undef;
}

# SM976 F2 (ruled 2026-10-09, "Confine both"): A FORM IS REACHED THROUGH THE
# PAGES THAT BIND IT. Forms carry no domain; a confined caller listed another
# domain's form and rewrote its upload settings (Q15c). So a confined caller
# reaches a form only when every page binding it lies inside its scope - one
# page outside is another site's visitors posting to it - and a form no page
# binds counts as the primary's, reached as caller_may_reach_domain reaches the
# primary (an unbound grant does, a scoped one does not). Unconfined callers are
# not asked. Takes the predicate's `scopes => [...]` override, and `bindings`
# (form_bindings' map) so a listing walks the site once rather than per form.
sub caller_may_reach_form {
    my ( $name, %who ) = @_;
    my %by = _who(%who);
    return 1 unless _confined_who(%by);
    my @pages = ref $who{bindings} eq 'HASH'
        ? @{ $who{bindings}{ lc( $name // '' ) } || [] }
        : form_pages($name);
    return caller_may_reach_domain( %by, host => '' ) ? 1 : 0 unless @pages;
    for my $p (@pages) { return 0 unless caller_may_reach_path( $p, %by ) }
    return 1;
}

# The refusal for a form this caller does not reach, or undef. It is given
# before the form is looked at, so another site's form and a form that does not
# exist get the same answer.
sub form_reach_refusal {
    my ( $name, %who ) = @_;
    my %by = _who(%who);
    return undef if caller_may_reach_form( $name, %by );
    my @mine = reachable_domains(%by);
    return { ok => 0, kind => 'forbidden', domains => \@mine,
        error => "You cannot reach the form '" . ( $name // '' ) . "'. A domain-confined "
            . 'caller reaches only the forms bound (front matter "form: NAME") on pages inside '
            . 'its scope; a form no page binds is the primary site\'s'
            . ( @mine ? '. Your domains: ' . join( ', ', @mine ) . '.' : '.' ) };
}

# SM976 Q15e/Q15f: the form a page's text binds, lower-cased, as a list (empty
# or one). One reading since Q15f - page_form, the processor's - which is also
# the reading form_bindings walks, so the write rule and the reach rule agree
# on what a page binds.
sub page_form_names {
    my ( $text, $rel ) = @_;
    my $f = page_form_or_none( $text, $rel );    # Q15h: a reading that dies binds nothing
    return defined $f ? ( lc $f ) : ();
}

# Does a form of this name exist anywhere: a registration (lazysite/forms/
# NAME.conf), a submissions store in the default place, or a page binding it?
# Case-insensitive, as form_bindings is. A form that exists nowhere has no
# settings and no submissions for a binding to take: naming it creates it, and
# it is the page's own - F2's reading for create_form ("a new name is the page's
# own"), which would otherwise be refused to every scoped caller, since a form
# no page binds counts as the primary's. Unknown (no docroot): it exists.
sub form_exists_anywhere {
    my ($name) = @_;
    return 1 unless defined $name && length $name;
    return 1 if form_pages($name);
    my $doc = ( defined $DOCROOT && length $DOCROOT ) ? $DOCROOT : ( $ENV{DOCUMENT_ROOT} // '' );
    return 1 unless length $doc;
    my $lz = Lazysite::Paths::lazysite_dir($doc);
    return 1 unless defined $lz && length $lz;
    for my $where ( [ "$lz/forms", '.conf' ], [ "$lz/forms/submissions", '.jsonl' ] ) {
        my ( $dir, $ext ) = @$where;
        opendir my $dh, $dir or next;
        my @hit = grep { /\A(.+)\Q$ext\E\z/ && lc($1) eq lc($name) } readdir $dh;
        closedir $dh;
        return 1 if @hit;
    }
    return 0;
}

# The text of the page at a docroot-relative path as it stands, from whichever
# tree holds it (the private store wins, as it does for every read), or undef.
sub _current_page_text {
    my ($rel) = @_;
    my $doc = ( defined $DOCROOT && length $DOCROOT ) ? $DOCROOT : ( $ENV{DOCUMENT_ROOT} // '' );
    return undef unless length $doc;
    my ($abs) = Lazysite::Private::resolve( $doc, $rel );
    return undef unless defined $abs && -f $abs && !-l $abs;
    return _read_as_processor($abs);
}

# SM976 Q15e (ruled 2026-10-09, "Refuse new binding"): A CONFINED CALLER BINDS NO
# FORM IT DOES NOT REACH. A form is reached through the pages that bind it (F2),
# so a page that newly names a form makes it the page's site's: a cookie manager
# scoped to one domain saved a page of its own naming the primary's form, then
# read that form's submissions (tmp/q15d-hijack-probe.out). Every content-write
# path asks this before it writes a page, with the text the page will hold.
#
# Refused when the page at $rel (a .md, the pages the processor renders forms
# on) would name a form it does not name now and that the caller does not reach
# - judged by caller_may_reach_form on the form's current bindings, as if the
# page were not yet written. Editing a page that already binds the form, and
# removing a binding, are unchanged. The operator and an unbound cookie manager
# are not asked, and a grant naming no scope reaches every form (R3). Shaped as
# the other content-write rules (error, or error and audit detail), so the
# choke point and the WebDAV stack share it (t/lint/114, t/lint/218).
sub form_bind_refusal {
    my ( $rel, $text, %who ) = @_;
    return unless defined $rel;
    ( my $r = $rel ) =~ s{^/+}{};
    return unless $r =~ /\.md\z/;
    my %by = _who(%who);
    return unless _confined_who(%by);
    my @names = page_form_names( $text, $r );
    return unless @names;
    my %had = map { $_ => 1 } page_form_names( _current_page_text($r), $r );
    my @new = grep { !$had{$_} && form_exists_anywhere($_) && !caller_may_reach_form( $_, %by ) } @names;
    return unless @new;
    my $f = $new[0];
    return _refusal(
        "The page '$r' would bind the form '$f' (front matter \"form: $f\"), which you do not "
            . 'reach. A domain-confined caller binds no form it does not reach: a form is reached '
            . 'through the pages that bind it, so a new binding would hand it a form of another '
            . 'site, or the primary\'s, with its submissions. Editing a page that already binds a '
            . 'form, and removing a binding, are unchanged. Bind a form of your own (create_form '
            . 'with a new name).',
        'form-bind-refused',
        "the page '$r' would newly bind the form '$f', which the caller does not reach",
        'bind a form of its own, or edit only a page that already binds this one'
    );
}

# The same rule for a write that carries existing files to a new place - a
# move, a rename, a copy, a package's content: every file under $src_abs (one
# file, or a folder), judged at the path it will have under $dst_rel. A move or
# a copy of a binding page is a new binding where it lands. Returns the first
# refusal.
sub form_bind_tree_refusal {
    my ( $src_abs, $dst_rel, %who ) = @_;
    return unless defined $src_abs && defined $dst_rel && -e $src_abs;
    my %by = _who(%who);
    return unless _confined_who(%by);
    ( my $dst = $dst_rel ) =~ s{^/+|/+$}{}g;
    my @pairs;
    if ( -d $src_abs ) {
        ( my $src = $src_abs ) =~ s{/+$}{};
        require File::Find;
        File::Find::find(
            { no_chdir => 1,
                wanted => sub {
                    my $p = $File::Find::name;
                    return if -l $p || !-f $p;
                    my $sub = substr( $p, length($src) + 1 );
                    push @pairs, [ $p, length $dst ? "$dst/$sub" : $sub ];
                },
            },
            $src
        );
    }
    elsif ( -f $src_abs && !-l $src_abs ) { @pairs = ( [ $src_abs, $dst ] ) }
    for my $pr ( sort { $a->[1] cmp $b->[1] } @pairs ) {
        next unless $pr->[1] =~ /\.md\z/;
        # A page that cannot be read cannot be judged: refused, not passed.
        my $t = _read_as_processor( $pr->[0] );
        defined $t
            or return _refusal( "The page '$pr->[1]' could not be read to check the form it binds.",
            'form-bind-refused', "the page '$pr->[1]' could not be read to check its form binding",
            'make it readable, or move the folder without it' );
        my @no = form_bind_refusal( $pr->[1], $t, %by );
        return wantarray ? @no : $no[0] if @no;
    }
    return;
}

# SM976 F2: a table's reach, by the data surface's rule (R4): a table naming a
# domain is that domain's, one naming none is everyone's. For a brief keyed on a
# row (`.typed/row/<table>/<key>`), whose table may since have gone.
sub caller_may_reach_table {
    my ( $table, %who ) = @_;
    my %by = _who(%who);
    return 1 unless _confined_who(%by);
    require Lazysite::Data::Tables;
    my $doc = ( defined $DOCROOT && length $DOCROOT ) ? $DOCROOT : ( $ENV{DOCUMENT_ROOT} // '' );
    my $d = eval { Lazysite::Data::Tables::load_table( $doc, $table ) };
    my $dom = ( ref $d eq 'HASH' && $d->{ok} && defined $d->{domain} && !ref $d->{domain} ) ? $d->{domain} : '';
    return 1 unless length $dom;
    return caller_may_reach_domain( %by, host => $dom ) ? 1 : 0;
}

# SM976 F2 (ruled 2026-10-09, "Confine both"): A BRIEF IS ITS SUBJECT'S. A brief
# about a content path is reached when the path is (caller_may_reach_path); one
# about a row (typed, or a store path under .typed/) when its table passes the
# data rule. A confined caller appended to and read another domain's page brief
# (Q15c). %o carries the typed reference (type, table) and `scopes`.
sub caller_may_reach_brief {
    my ( $path, %o ) = @_;
    my %by = _who(%o);
    return 1 unless _confined_who(%by);
    my $table;
    if ( length( $o{type} // '' ) ) { $table = $o{table} }
    else {
        ( my $p = $path // '' )                           =~ s{^/+}{};
        return caller_may_reach_path( $p, %by ) unless $p =~ m{\A\.typed/[^/]+/([^/]+)(?:/|\z)};
        $table = $1;
    }
    return 0 unless defined $table && length $table;
    return caller_may_reach_table( $table, %by );
}

# The refusal for a brief this caller does not reach, or undef.
sub brief_reach_refusal {
    my ( $path, %o ) = @_;
    return undef if caller_may_reach_brief( $path, %o );
    my %by   = _who(%o);
    my @mine = reachable_domains(%by);
    my $what = length( $o{type} // '' )
        ? "the brief of a row of '" . ( $o{table} // '' ) . "'"
        : "the brief of '" . ( $path // '' ) . "'";
    return { ok => 0, kind => 'forbidden', domains => \@mine,
        error => "You cannot reach $what. A domain-confined caller reaches only the briefs of "
            . 'pages inside its scope, and of rows of the tables its domains hold'
            . ( @mine ? ' (' . join( ', ', @mine ) . ').' : '.' ) };
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
# If the handler config cannot be read the answer is the default prefix alone,
# which is what this function did before it knew about configured stores. That
# is SAFE for the default store and OPEN for a configured one - so a caller must
# have set the Manager modules' DOCROOT before asking. SM851: MCP asked before
# its setup_context, under CGI that was every request, and a store at a
# handler's own path was read without read_submissions. The handler reader now
# logs when it has no docroot, which is how that came to light.
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
# The raw nav.conf needs manage_nav, to read or write, here and over WebDAV, as
# nav-save does (the STRUCTURED read, nav-read/read_nav, needs no capability:
# SM943 ruling 2); the
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
#
# Resolve the real content processor to shell for a server-side render.
#
# We must NOT shell $ENV{LAZYSITE_PROCESSOR} directly: in the wrapped
# deployment (Apache/Hestia and the dev server) the auth wrapper sets
# LAZYSITE_PROCESSOR to the ORIGINALLY requested CGI - which is THIS
# manager-api when a preview action runs - so trusting it re-enters
# manager-api (auth stripped -> "Authentication required") instead of the
# processor. Take only the cgi-bin DIRECTORY it names and resolve the
# processor by its own name there, falling back to the docroot-relative path.
sub processor_path {
    my $lp  = $ENV{LAZYSITE_PROCESSOR};
    my $dir = ( defined $lp && length $lp )
        ? File::Basename::dirname($lp)
        : "$DOCROOT/../cgi-bin";
    return "$dir/lazysite-processor.pl";
}

# SM670 (ruled 2026-09-11): the HTTP status a control-API refusal answers with,
# by its kind. Anything not listed - and a refusal with no kind - is the
# caller's request refused: 400. `partial` is 207: part of the write happened,
# so it is neither a success a status-keying client would skip nor a 4xx that
# invites retrying a half-applied write. Server-side failures are 500.
#
# EVERY KEY HERE IS HYPHENATED, AND SIX KINDS IN THE TREE ARE NOT (SM872). A
# kind the map does not know is not an error anywhere - it silently takes the
# 400 default - so `no_such_table` answered "your request was malformed" for a
# table that is simply absent, while lazysite-data.pl answered 404 for the same
# condition. Two surfaces, two answers, no test in between. They are listed
# below beside their hyphenated equivalents rather than renamed: `kind` is read
# by clients and asserted across the suite, and a more specific name is worth
# keeping - it is the STATUS that was wrong, not the vocabulary.
#
# t/lint/139 holds this closed: every `kind => '...'` the tree emits is either
# a key here or named in that test's "400 is the right answer" list.
our %REFUSAL_STATUS = (
    ( map { $_ => '403 Forbidden' } qw(forbidden not-yours permission blocked disabled served-artifact-refused form-bind-refused) ),
    ( map { $_ => '404 Not Found' }
            qw(not-found unknown-domain
            no_such_table no_such_row no_such_form db-table-missing) ),
    ( map { $_ => '409 Conflict' }
            qw(exists in-use confirm needs_confirmation has_submissions conflict) ), # SM858
    'too-large' => '413 Payload Too Large',
    'page-encoding-refused' => '415 Unsupported Media Type', # SM976 Q15h: the content, not the request
    'rate'      => '429 Too Many Requests',
    'partial'   => '207 Multi-Status',
    # SM873: `store-uninspectable` joins them. The data store failing to open
    # or answer is this host unable to read its own state, not a malformed
    # request - and it used to answer 400, because the kind was assembled from
    # a runtime reason and could never match a key here. The refusal carries
    # `reason` for which fault it was; see Data::Tables.
    ( map { $_ => '500 Internal Server Error' }
            qw(render-failed snapshot-failed no-cgi-headers empty-render store-uninspectable) ),
    # SM906 T3: an auth store exists and the web server cannot read it, so the
    # engine cannot tell what the caller may do. Not 403 - nothing was decided
    # about the caller - and not 500: the host is up and says exactly which
    # file to repair. 503 is "cannot serve this now", which is the truth.
    'cannot-tell' => '503 Service Unavailable',

    # SM747: the Odoo extension's kinds (Lazysite::Odoo::fault and its gate).
    # Odoo answering badly is a BAD GATEWAY - the request was fine and the
    # upstream was not - except where Odoo refused this caller's operation
    # (403) or the record is gone (404). A plan that can no longer apply is a
    # conflict with the state it was made against; an expired one is gone.
    ( map { $_ => '403 Forbidden' } qw(mode scope-refused odoo-access-refused read-only no-owner) ),
    ( map { $_ => '404 Not Found' } qw(no-operation odoo-missing) ),
    ( map { $_ => '409 Conflict' } qw(stale applied edited binding instance) ),
    'expired' => '410 Gone',
    ( map { $_ => '502 Bad Gateway' } qw(transport-failure odoo-fault invalid-credential session-expired) ),
    'odoo-validation'  => '422 Unprocessable Content',
    'apply-incomplete' => '207 Multi-Status',
    'internal'         => '500 Internal Server Error',
    ( map { $_ => '503 Service Unavailable' } qw(unavailable no-key config) ),
);

sub refusal_status {
    my ($kind) = @_;
    return ( defined $kind && $REFUSAL_STATUS{$kind} ) || '400 Bad Request';
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

    # SM670: A REFUSAL SAYS SO IN THE STATUS LINE TOO. Every refusal used to
    # answer 200 with ok:false, so a client that checks the status first - the
    # idiomatic shape in every language - saw success and then failed on a body
    # it did not expect. The status comes from the refusal's kind
    # (refusal_status); the body is unchanged and keeps ok:false for good, so
    # the two registers agree rather than one replacing the other.
    my $status = ( ref $data eq 'HASH' && exists $data->{ok} && !$data->{ok} )
        ? refusal_status( $data->{kind} )
        : '200 OK';

    # encode_json already emits UTF-8 bytes; print raw (a :utf8 layer would
    # double-encode non-ASCII content into mojibake).
    binmode(STDOUT);
    print "Status: $status\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n\r\n";
    print encode_json($data);
}

# --- SM944 S23b: the script's own JSON responses ---------------------------
#
# Moved out of lazysite-manager-api.pl (ruled 2026-10-09); the script imports it.

# The four responses lazysite-manager-api.pl prints itself rather than handing
# to respond(): the OPTIONS refusal and the rate-limit 429 (both need their own
# status), and the two preview verbs (both need Set-Cookie). Content-Type is
# always last before the blank line, and STDOUT is always put in binmode first -
# encode_json emits UTF-8 bytes and must not be re-encoded.
sub _emit_json {
    my ( $status, $headers, $body ) = @_;
    binmode(STDOUT);
    print "Status: $status\r\n";
    print "$_\r\n" for @{ $headers || [] };
    print "Content-Type: application/json; charset=utf-8\r\n\r\n";
    print encode_json($body);
    return;
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

    # N13-30: manager_upload_blocked_paths, the key's old name, is not read. The
    # upgrade renames it (install.pl) and lazysite-check reports one left behind;
    # pre-stable, an alias kept alive is a second way to say one thing.
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
# SM750: WHAT A REFUSAL MUST SAY. Two forms of the same fact:
#
#   error        - the caller's sentence(s): what was refused, why, and what to
#                  do instead. Long is fine; the reader is a person or an agent
#                  deciding its next call.
#   audit_detail - one scannable line for the trail: `kind: cause - remedy`.
#                  Short, no host paths (SM739), and complete enough that a
#                  reader of the log does not have to find the caller's screen
#                  to learn what happened. The dispatchers prefer it over `kind`
#                  (SM711 half 2), which is how `raw-content-refused` alone
#                  stopped being what the trail said.
#
# Every content-write rule below returns BOTH in list context and the error
# alone in scalar context, so the choke point can record the detail and the
# DAV stack's existing scalar calls are untouched. t/lint/115 holds the shape:
# for each rule, a triggering input yields a detail of exactly this form.
sub refusal_detail {
    my ( $kind, $cause, $remedy ) = @_;
    for ( $cause, $remedy ) { $_ //= ''; s/\s+/ /g; s/\s+\z//; s/\.\z// }
    return "$kind: $cause - $remedy";
}

# THE EARLY RETURNS IN THESE RULES ARE BARE `return`, not `return undef`: in
# list context `undef` is a one-element list, and the choke point's
# `if ( my ($e, $d) = rule() )` would read every accepted write as a refusal
# with an undefined error. Found by t/unit/mcp/05 the first time it was tried.
sub _refusal {
    my ( $error, $kind, $cause, $remedy ) = @_;
    return wantarray ? ( $error, refusal_detail( $kind, $cause, $remedy ) ) : $error;
}

sub brief_write_refusal {
    my ($rel) = @_;
    return unless defined $rel && $rel =~ /\.brief\z/;
    require Lazysite::Manager::Plugins;
    # The api and mcp set Common's $DOCROOT in their setup blocks; the DAV
    # process never does - it carries the docroot in the environment. An
    # empty docroot must read as "cannot tell", never as "disabled": no
    # refusal, the write proceeds, exactly as before SM504.
    my $droot = ( defined $DOCROOT && length $DOCROOT ) ? $DOCROOT : ( $ENV{DOCUMENT_ROOT} // '' );
    return unless length $droot;
    # SM557: the package is require'd at runtime, so this file mentions the
    # variable once by design - t/lint/04 refuses the 'used only once' warning.
    no warnings 'once';
    local $Lazysite::Manager::Plugins::DOCROOT = $droot;
    return
        unless eval { Lazysite::Manager::Plugins::plugin_enabled('plugins/briefs.pl') };
    return _refusal(
        'This site holds briefs in the brief store, not in .brief sidecar '
            . 'files - a sidecar written here would be an inert file no listing '
            . 'shows and no migration imports, a note nobody reads. Append to the '
            . "record instead: append_brief over MCP, or brief-append on the "
            . 'control API, with {path, entry}. Reading an existing sidecar still '
            . 'works.',
        'brief-sidecar-refused',
        'this site keeps briefs in the brief store, not .brief sidecars',
        'append_brief / brief-append with {path, entry}'
    );
}

# SM749: the theme or layout BEING SERVED is read-only, on every surface.
#
# WebDAV has refused a write into the active theme since SM071; the manager,
# the control API and MCP wrote it without comment, through action_save, which
# had never heard of the rule. Same write, refused on one surface and accepted
# on two, and the theme under visitors changed either way. That is SM748's
# shape with the surfaces reversed: a rule in one CALLER protects that caller.
#
# The rule is right, and the release manager confirmed the intent: a live theme
# changes by COPY, EDIT, ACTIVATE. A theme apply is atomic - the pointer moves
# once, the mirror is rebuilt once - and a stream of single-file writes into
# the directory being rendered is not; a visitor between two of them gets half
# of each. So the rule lives here, beside the other content-write rules, and is
# consulted by the choke point and by the DAV stack, which is what t/lint/114
# holds for every rule in this family.
#
# THE MESSAGE NAMES THE WORKFLOW, NOT AN ESCAPE. The old DAV text offered two
# ways round within WebDAV ("switch the active theme first, or edit a
# non-active one"); a partner agent read it and concluded that theme editing
# needed a different surface - reasoning correctly from a message that said
# what was refused and not what to do. Now every surface refuses, there is one
# right answer, and this is it. Pure: the caller passes the active pointers,
# so the two stacks read their own configuration and share the rule.
#
# Returns the refusal text, or undef when $rel is not inside the active theme
# or the active layout (including any path that is not under lazysite/layouts).
sub active_artifact_refusal {
    my ( $rel, $active_layout, $active_theme ) = @_;
    return unless defined $rel;
    $rel =~ s{^/+}{};
    my ( $layout, $rest ) = $rel =~ m{^lazysite/layouts/([^/]+)(?:/(.*))?$};
    return unless defined $layout;
    $rest          //= '';
    $active_layout //= '';
    $active_theme  //= '';
    return unless length $active_layout && $layout eq $active_layout;

    if ( $rest =~ m{^themes/([^/]+)} ) {
        my $theme = $1;
        return unless length $active_theme && $theme eq $active_theme;
        return _refusal(
            "the active theme '$theme' (layout '$layout') is being served "
                . 'and is read-only on every surface. To change a live theme: copy it '
                . "(copy_theme over MCP, theme-copy on the control API, or Copy on the "
                . 'manager Themes page), edit the copy, then activate the copy '
                . '(activate_theme / theme-activate). A theme apply is atomic; a file '
                . 'written into the theme being rendered is not.',
            'active-artifact-refused',
            "theme '$theme' is the one being served",
            'copy_theme / theme-copy, edit the copy, then activate it'
        );
    }

    # The layout's own files (layout.tt, its assets) and its structure. A
    # layout has no copy verb - it is installed from a release - so the
    # workflow is install-or-edit-another, then activate.
    return _refusal(
        "the active layout '$layout' is being served and is read-only on "
            . 'every surface. To change a live layout: install the new version '
            . 'under another name (install_layout / layout-install) or edit a '
            . 'layout that is not active, then activate it (activate_layout / '
            . 'layout-activate). A layout apply is atomic; a file written into the '
            . 'layout being rendered is not.',
        'active-artifact-refused',
        "layout '$layout' is the one being served",
        'install or edit another layout, then activate it'
    );
}

sub raw_html_page_refusal {
    my ($content) = @_;
    return unless defined $content;
    return unless $content =~ /\A---\s*\n(.*?)\n---\s*\n/s;    # front-matter block
    my $fm = $1;
    return
        unless $fm =~ /^api\s*:\s*true\b/mi || $fm =~ /^raw\s*:\s*true\b/mi;
    my ($ct) = $fm =~ /^content_type\s*:\s*(.+?)\s*$/mi;
    return
        unless defined $ct
        && $ct =~ m{^\s*(?:text/html|application/xhtml\+xml|image/svg\+xml)\b}i;
    my $key = ( $fm =~ /^api\s*:\s*true\b/mi ) ? 'api' : 'raw';
    # SM228: name the alternative, not only the prohibition. The reader here is
    # usually someone who wants a self-contained HTML file served unchanged, and
    # `raw:` is the front-matter key whose name invites exactly that. The answer -
    # publish it as a STATIC FILE, which lazysite serves byte-for-byte and which
    # accepts .html/.js on every authoring channel - is a different mechanism, and
    # nothing previously connected the two.
    return _refusal(
        "This page declares a raw HTML content type ($ct), which a content page "
            . "may not use: raw HTML/SVG bypasses the layout and theme and is served "
            . "as plain text (ADR 0006), and external CSS/font/CDN links are refused. "
            . "What to do instead: to publish a self-contained HTML file unchanged, "
            . "write it as a STATIC FILE (e.g. app/index.html) - a .html with no .md "
            . "source is served byte-for-byte, with no Markdown pipeline, layout or "
            . "theme, and .html/.js are writable on every authoring channel. For an "
            . "ordinary page, author Markdown and let the layout and theme style it. "
            . "For a genuine data artifact, use a non-script content type such as "
            . "application/json.",
        'raw-content-refused',
        "front matter has $key: true with content_type $ct",
        'publish a self-contained HTML file as a static .html, or author '
            . 'Markdown and let the layout and theme style it'
    );
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
    my ( $body, $offset ) = @_;
    my $issues = [];
    return () unless defined $body && $body =~ /\[%/;

    # SM900: THE LINE IS A FILE LINE. The parser sees a text that exists only
    # here - the body with the front matter gone and every code-block line
    # dropped - and its "line N" counted THAT. The W11 walk reported an
    # unclosed [% IF %] on file line 11 as line 7, while the fence check on the
    # same page said 8 for a fence on line 8, because that check adds the
    # front-matter offset back (SM488). Two checks, two origins. So @orig
    # remembers, for each kept line, the BODY line it came from, and $offset -
    # the lines the caller removed above the body - completes the sum.
    $offset //= 0;

    # Strip what the processor protects, plus anything ambiguous.
    #
    # SM744: an indented line is a Markdown code block ONLY where one can
    # begin - after a blank line. The rule used to fire on any four-space
    # indent, which ate the continuation lines of a multi-line directive:
    #
    #     [%# a comment whose text runs on
    #         and whose closing tag is over here %]
    #     [%- FOREACH x IN xs -%]
    #
    # dropping lines 2-3 took the closing %] with them, so the truncated
    # comment swallowed the FOREACH and its END was reported as unexpected
    # far below. The page parsed; only this copy of it did not. Five of the
    # seven refusals measured across every reachable tree were that, and all
    # five were real pages.
    #
    # A directive's continuation never follows a blank line, so requiring one
    # separates the two cases without the stripper needing to know any
    # template syntax.
    my ( @keep, @orig, $in_fence, $in_indent_code );
    my $prev_blank = 1;    # the top of the body is a place a block may begin
    my $body_line  = 0;
    for my $line ( split /\n/, $body ) {
        $body_line++;
        if ( $line =~ /^[ \t]{0,3}(?:```|~~~)/ ) {
            $in_fence   = !$in_fence;
            $prev_blank = 0;
            next;
        }
        next if $in_fence;

        my $blank = $line =~ /^\s*$/ ? 1 : 0;
        if ( $line =~ /^(?: {4}|\t)/ && ( $in_indent_code || $prev_blank ) ) {
            $in_indent_code = 1;
            $prev_blank     = 0;
            next;
        }

        # A blank line does not close an indented block - indented lines may
        # resume after it - but any other unindented line does.
        $in_indent_code = 0 unless $blank;
        $prev_blank     = $blank;
        push @keep, $line;
        push @orig, $body_line;
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
    if ( defined $line ) {
        # The parser's line, mapped back to the file. A number outside the
        # kept text would be a wrong answer dressed as a line; leave it out.
        my $at = ( $line >= 1 && $line <= @orig ) ? $orig[ $line - 1 ] : undef;
        $line = defined $at ? $at + $offset : undef;
    }
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
    return unless defined $path    && $path    =~ /\.md$/i;
    return unless defined $content && $content =~ /\[%/;
    my $body = $content;
    # SM900: the lines stripped here are lines the reported number must count.
    my $offset = 0;
    if ( $body =~ s/\A(---\n.*?\n---\n)//s ) {
        $offset = () = $1 =~ /\n/g;
    }
    my @issues = page_parse_issues( $body, $offset );
    return unless @issues;
    my ($said) = $issues[0]{message} =~ /Parser said: (.*)\z/s;
    return _refusal(
        $issues[0]{message},
        'template-parse-refused',
        'the page template does not parse'
            . ( defined $issues[0]{line} ? " (line $issues[0]{line})" : '' )
            . ( defined $said            ? ": $said"                  : '' ),
        'fix the template syntax; a literal [% in page JavaScript belongs in a '
            . 'data- attribute'
    );
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
