package Lazysite::Manager::Common;

# Shared path / deny / write / respond helpers for the manager (SM079). The
# per-request ambient context ($DOCROOT, $action, $auth_user) is set by the
# dispatcher as package variables, so the handler bodies that use these helpers
# move verbatim. The deny list @BLOCKED_PATHS is owned here.

use strict;
use warnings;
use Cwd            qw(realpath);
use Errno          ();                # %! (errno names) for the permission-failure hint
use File::Basename qw(dirname basename);
use Fcntl          qw(:flock);
use JSON::PP       qw(encode_json);
use Lazysite::Util qw(log_event);
use Exporter 'import';

our @EXPORT_OK = qw(validate_path is_blocked_path write_file_checked respond
    is_blocked_config is_blocked_upload_target upload_limits load_upload_limits _reset_upload_limits_cache
    _write_conf_key path_out_of_scope outside_all_scopes reserved_roots path_is_reserved);

our $DOCROOT;                         # set by the script
our $action    = '';                  # current request action (for log attribution)
our $auth_user = '';                  # current request user (for log attribution)

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
    $rel =~ s{^/+|/+$}{}g;
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
    if ( $rel_path =~ m{\Alazysite/}
        && $rel_path !~ m{\Alazysite/forms/submissions/}
        && $rel_path !~ m{\Alazysite/layouts/}
        && $rel_path !~ m{\Alazysite/themes/}
        && $rel_path !~ m{\Alazysite/nav\.conf\z} )
    {
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

sub _write_conf_key {
    my ( $key, $value ) = @_;
    # An empty value is allowed (writes "key:" - used to CLEAR a key, e.g.
    # canonical_ip = auto-detect); the caller is the emptiness gate. The key
    # itself must be present and name-shaped.
    return 0 unless defined $key && length $key && defined $value;
    return 0 unless $key =~ /^[A-Za-z_][A-Za-z0-9_-]*$/;

    my $conf_path = "$DOCROOT/lazysite/lazysite.conf";

    # Serialise concurrent writers. The Services page saves every changed key as
    # its own config-set, fired in parallel (Promise.all), so several processes
    # reach this read-modify-write at once. Without a lock, the second saver's
    # write drops the first's change (lost update); combined with the old
    # non-atomic write it truncated the whole file. Hold an exclusive lock on a
    # sidecar lockfile across the read-modify-write so the writes serialise;
    # write_file_checked keeps each write atomic. Readers stay lock-free - the
    # atomic rename means they always see a complete file.
    open my $lock, '>', "$conf_path.lock"
        or return wantarray ? ( 0, "Cannot lock lazysite.conf: $!" . _perm_hint() ) : 0;
    unless ( flock $lock, LOCK_EX ) {
        my $err = "$!";
        close $lock;
        return wantarray ? ( 0, "Cannot lock lazysite.conf: $err" ) : 0;
    }

    my $content = '';
    if ( -f $conf_path ) {
        open my $fh, '<:utf8', $conf_path
            or do { close $lock; return wantarray ? ( 0, "Cannot read lazysite.conf: $!" ) : 0 };
        $content = do { local $/; <$fh> };
        close $fh;
    }

    if ( $content =~ /^$key\s*:/m ) {
        $content =~ s/^$key\s*:.*$/$key: $value/m;
    }
    else {
        $content =~ s/\n?$/\n/;
        $content .= "$key: $value\n";
    }

    my ( $ok, $err ) = write_file_checked( $conf_path, $content );
    close $lock;    # releases the exclusive flock
                    # Scalar callers keep the boolean contract; a list caller (config-set)
                    # also gets the underlying error, incl. the permission hint.
    return wantarray ? ( $ok ? 1 : 0, $err ) : ( $ok ? 1 : 0 );
}

1;
