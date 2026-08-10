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
use Exporter 'import';

our @EXPORT_OK = qw(validate_path is_blocked_path write_file_checked respond
    is_blocked_config is_blocked_upload_target upload_limits load_upload_limits _reset_upload_limits_cache
    _write_conf_key write_conf_key write_conf_content conf_batch path_out_of_scope outside_all_scopes reserved_roots path_is_reserved
    carveout_requirement carveout_refusal path_leads_to_carveout
    raw_html_page_refusal processor_path);

our $DOCROOT;                           # set by the script
our $action    = '';                    # current request action (for log attribution)
our $auth_user = '';                    # current request user (for log attribution)

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
    # the per-file ACLs and the session HMAC secret - which forges operator
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

    my $full  = "$DOCROOT/$rel_path";
    my $check = -e $full ? $full : dirname($full);
    my $real  = realpath($check);

    # SEC-2026-07 (H3): boundary-safe containment. A bare index($real,$DOCROOT)
    # prefix test also passed for a SIBLING whose name is a string-superset of
    # the docroot (public_html vs public_html.bak), letting a write escape the
    # docroot. Require equality or a "$DOCROOT/" prefix.
    return { ok => 0, error => "Invalid path" }
        unless $real && ( $real eq $DOCROOT || index( $real, "$DOCROOT/" ) == 0 );

    # The blocklist string-matches on rel, so rel MUST be the CANONICAL in-docroot
    # path, never the request spelling. Derive it from the resolved realpath
    # ($real is the file itself, or its parent dir when the file does not exist
    # yet); re-attach the basename in that case. Callers get a full that is the
    # resolved absolute path too, so a symlink can't point a write elsewhere.
    my $canon = ( -e $full ) ? $real : "$real/" . basename($full);
    ( my $rel = $canon ) =~ s{\A\Q$DOCROOT\E/?}{};

    return { ok => 1, full => $canon, rel => $rel };
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
our @LAZYSITE_OPEN_PREFIXES = ( 'lazysite/forms/submissions/', 'lazysite/layouts/', 'lazysite/themes/' );
our @LAZYSITE_OPEN_EXACT = ('lazysite/nav.conf');

sub _is_carveout {
    my ($rel) = @_;
    for my $e (@LAZYSITE_OPEN_EXACT)    { return 1 if $rel eq $e }
    for my $p (@LAZYSITE_OPEN_PREFIXES) { return 1 if index( $rel, $p ) == 0 }
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
            return 1;
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
        return 1;
    }
    # SEC-2026-07: never write/serve an executable or server-config extension.
    if ( $rel_path =~ $DANGEROUS_RE ) {
        log_event( 'WARN', $action, 'blocked path access', path => $rel_path, user => $auth_user );
        return 1;
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
    if ( index( $r, 'lazysite/forms/submissions/' ) == 0 ) {
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

# A permission failure is server-truthful but operator-opaque ("Permission
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
    # encode_json already emits UTF-8 bytes; print raw (a :utf8 layer would
    # double-encode non-ASCII content into mojibake).
    binmode(STDOUT);
    print "Status: 200 OK\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n\r\n";
    print encode_json($data);
}

our $_upload_limits_cache;

sub load_upload_limits {
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

    my $conf_path = "$DOCROOT/lazysite/lazysite.conf";
    return \%limits unless -f $conf_path;

    my $new_key_seen = 0;
    my $old_key_seen = 0;
    open my $fh, '<', $conf_path or return \%limits;
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
                $limits{blocked_paths} = [
                    map { my $p = $_; $p =~ s{^/+|/+$}{}g; $p }
                        grep { length }
                        split /\s*,\s*/, $v
                ];
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
                $limits{_deprecated_blocked_paths} = [
                    map { my $p = $_; $p =~ s{^/+|/+$}{}g; $p }
                        grep { length }
                        split /\s*,\s*/, $v
                ];
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
            return 1;
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
                return 1;
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

# =========================================================================
# SM255: ONE write path for lazysite.conf
# =========================================================================
#
# The commit is a property of WRITING THIS FILE, not of the action that happened
# to do it. An operator does not know or care whether a change arrived through
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

sub _conf_path_of { return "$DOCROOT/lazysite/lazysite.conf" }

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
