#!/usr/bin/perl
# lazysite-manager-api.pl - file operations CGI for lazysite manager
use strict;
use warnings;
use Digest::SHA qw(hmac_sha256_hex);
use JSON::PP qw(encode_json decode_json);
use File::Find;
use File::Path qw(make_path);
use File::Basename qw(dirname basename);
use Cwd qw(realpath);
use IPC::Open2;
use Fcntl qw(O_RDWR O_CREAT);
use POSIX qw(strftime);

my $LOG_COMPONENT = 'manager-api';

my $DOCROOT      = $ENV{DOCUMENT_ROOT} // die "No DOCUMENT_ROOT\n";
my $LAZYSITE_DIR = "$DOCROOT/lazysite";
my $LOCK_DIR     = "$LAZYSITE_DIR/manager/locks";
my $LOCK_TIMEOUT = 300;

my @BLOCKED_PATHS = (
    'lazysite/auth/.secret',
    'lazysite/forms/.secret',
    'lazysite/auth/users',
    'lazysite/auth/groups',
);

# SM019: download Content-Type table. Unknown extensions fall back to
# application/octet-stream so the browser treats the body as raw bytes.
my %CONTENT_TYPE_MAP = (
    md    => 'text/plain; charset=utf-8',
    txt   => 'text/plain; charset=utf-8',
    html  => 'text/html; charset=utf-8',
    htm   => 'text/html; charset=utf-8',
    css   => 'text/css; charset=utf-8',
    js    => 'text/javascript; charset=utf-8',
    json  => 'application/json; charset=utf-8',
    jsonl => 'application/jsonl; charset=utf-8',
    xml   => 'application/xml; charset=utf-8',
    yaml  => 'text/yaml; charset=utf-8',
    yml   => 'text/yaml; charset=utf-8',
    csv   => 'text/csv; charset=utf-8',
    png   => 'image/png',
    jpg   => 'image/jpeg',
    jpeg  => 'image/jpeg',
    gif   => 'image/gif',
    webp  => 'image/webp',
    svg   => 'image/svg+xml',
    ico   => 'image/vnd.microsoft.icon',
    pdf   => 'application/pdf',
    zip   => 'application/zip',
);

# SM019: extensions treated as editable text by the manager editor.
# Paths whose extension is not listed here are treated as binary and
# the editor shows a download panel instead of CodeMirror. Dotfiles
# like .htaccess match the regex with "htaccess" as the extension,
# which is not in this list, so they are treated as binary. That is
# intentional - a browser textarea is the wrong tool for .htaccess.
my %TEXT_EXTENSIONS = map { $_ => 1 } qw(
    md txt html htm css js json jsonl xml
    yaml yml csv tsv conf ini log pl pm
    sh bash env example
);

# SM019: unit-test hook. When set, `do "lazysite-manager-api.pl"` from a
# test returns after the lexicals are initialised but before the auth
# check, request parsing, and dispatch, so tests can exercise helper
# subs directly (parse_multipart_body, detect_content_type, etc.)
# without spawning a subprocess. Has no effect in normal CGI use.
return 1 if $ENV{LAZYSITE_API_LOAD_ONLY};

# --- Auth check ---

# Read manager_groups from lazysite.conf to determine if auth is required
my $manager_groups_conf = '';
if ( open my $cfh, '<', "$LAZYSITE_DIR/lazysite.conf" ) {
    while (<$cfh>) {
        $manager_groups_conf = $1 if /^manager_groups\s*:\s*(.+)/;
    }
    close $cfh;
}
$manager_groups_conf =~ s/^\s+|\s+$//g;

my $auth_user = $ENV{HTTP_X_REMOTE_USER} // '';
if ( $manager_groups_conf && !$auth_user ) {
    respond({ ok => 0, error => "Authentication required" });
    exit 0;
}
$auth_user ||= 'local';

# --- Parse request ---

my %params;
for my $pair ( split /&/, $ENV{QUERY_STRING} // '' ) {
    my ( $k, $v ) = split /=/, $pair, 2;
    next unless defined $k;
    $k =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    $v //= '';
    $v =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    $v =~ s/\+/ /g;
    $params{$k} = $v;
}

my $action = $params{action} // '';
my $path   = $params{path}   // '/';

my $body = '';
if ( ( $ENV{REQUEST_METHOD} // '' ) eq 'POST' ) {
    my $len = $ENV{CONTENT_LENGTH} // 0;

    # SM019: size + rate-limit gate for file-upload. Runs before the
    # body read so oversize or rate-exceeding requests are rejected
    # without allocating the body. Other POST actions carry small JSON
    # bodies and fall through to the normal read.
    if ( ( $params{action} // '' ) eq 'file-upload' ) {
        my $max = upload_limits()->{max_bytes};
        if ( $len > $max ) {
            log_event( 'WARN', 'file-upload', 'upload too large',
                size => $len, max => $max, user => $auth_user );
            respond({ ok => 0,
                error => "Upload exceeds limit of "
                       . int( $max / 1024 / 1024 ) . " MB" });
            exit 0;
        }
        my $rate = check_upload_rate( $auth_user, $len );
        unless ( $rate->{ok} ) {
            respond({ ok => 0, error => $rate->{error} });
            exit 0;
        }
    }

    read( STDIN, $body, $len ) if $len > 0;
}

# --- M-1: CSRF gate on write actions --------------------------------
# The gate is keyed on HTTP method, not action name. Every write action
# in this script is dispatched via POST; reads (list, cache-list,
# theme-list, plugin-list, nav-read, handler-list, form-targets-read,
# csrf-token itself, etc.) come in over GET and do not need a token.
# Going by method rather than an action allowlist means we cannot
# accidentally leave a new read action out of the list.
my $method = $ENV{REQUEST_METHOD} // 'GET';
if ( $method eq 'POST' ) {
    # Token can arrive via (in order of preference):
    #   - X-CSRF-Token header (HTTP_X_CSRF_TOKEN env var) - works for any
    #     body type including raw binary uploads (theme-upload).
    #   - csrf_token field in a JSON body - convenient for existing
    #     apiCall() patterns that send JSON.
    #   - csrf_token query-string parameter - last-resort fallback for
    #     sendBeacon() calls that cannot set headers.
    my $token = $ENV{HTTP_X_CSRF_TOKEN} // '';
    my $source = $token ? 'header' : '';
    if ( !$token && $body ) {
        my $parsed = eval { decode_json($body) };
        if ( ref $parsed eq 'HASH' ) {
            $token = $parsed->{csrf_token} // '';
            $source = 'body' if $token;
        }
    }
    if ( !$token ) {
        $token  = $params{csrf_token} // '';
        $source = 'query' if $token;
    }

    log_event('DEBUG', $action, 'CSRF check',
        method    => $method,
        user      => $auth_user,
        token_len => length($token),
        source    => $source || 'none',
        result    => $token ? 'has-token' : 'no-token');

    my $valid = verify_csrf_token( $token, $auth_user );

    log_event('DEBUG', $action, 'CSRF verify',
        user   => $auth_user,
        result => $valid ? 'ok' : 'fail');

    unless ( $valid ) {
        respond({ ok => 0, error => 'Invalid or missing CSRF token' });
        exit 0;
    }
}

# Per-action csrf-token read
if ( $action eq 'csrf-token' ) {
    respond({ ok => 1, token => generate_csrf_token($auth_user) });
    exit 0;
}

# --- Dispatch ---

my $result;
if    ( $action eq 'list' )             { $result = action_list($path) }
elsif ( $action eq 'read' )             { $result = action_read($path, $auth_user) }
elsif ( $action eq 'save' )             {
    my $req = eval { decode_json($body) } // {};
    $result = action_save( $path, $auth_user, $req->{content}, $req->{mtime} );
}
elsif ( $action eq 'delete' )           { $result = action_delete( $path, $auth_user ) }
elsif ( $action eq 'mkdir' )            { $result = action_mkdir($path) }
elsif ( $action eq 'lock' )             { $result = acquire_lock( $path, $auth_user ) }
elsif ( $action eq 'unlock' )           { $result = release_lock( $path, $auth_user ) }
elsif ( $action eq 'renew-lock' )       { $result = renew_lock( $path, $auth_user ) }
elsif ( $action eq 'preview' )          { $result = action_preview($path) }
elsif ( $action eq 'cache-list' )       { $result = action_cache_list() }
elsif ( $action eq 'cache-invalidate' ) { $result = action_cache_invalidate($path) }
elsif ( $action eq 'theme-list' )       { $result = action_theme_list() }
elsif ( $action eq 'theme-activate' )   { $result = action_theme_activate($path) }
elsif ( $action eq 'theme-delete' )     { $result = action_theme_delete($path) }
elsif ( $action eq 'theme-rename' )     {
    my $req = eval { decode_json($body) } // {};
    $result = action_theme_rename( $path, $req->{new_name} );
}
elsif ( $action eq 'theme-upload' )     { $result = action_theme_upload( $body, $params{filename} ) }
elsif ( $action eq 'users' )            { $result = action_users( $body, \%params ) }
elsif ( $action eq 'rotate-auth-secret' ) { $result = action_rotate_auth_secret( $auth_user ) }
elsif ( $action eq 'plugin-list' )      { $result = action_plugin_list() }
elsif ( $action eq 'plugin-enable' )    {
    my $req = eval { decode_json($body) } // {};
    $result = action_plugin_enable($req->{script});
}
elsif ( $action eq 'plugin-disable' )   {
    my $req = eval { decode_json($body) } // {};
    $result = action_plugin_disable($req->{script});
}
elsif ( $action eq 'plugin-read' )      {
    my $req = eval { decode_json($body) } // {};
    $result = action_plugin_read( $params{plugin}, $req->{script} );
}
elsif ( $action eq 'plugin-save' )      {
    my $req = eval { decode_json($body) } // {};
    $result = action_plugin_save( $params{plugin}, $req->{script}, $req->{values} // {} );
}
elsif ( $action eq 'plugin-action' )    {
    my $req = eval { decode_json($body) } // {};
    $result = action_plugin_action( $params{plugin}, $req->{script}, $req->{action_id} );
}
elsif ( $action eq 'nav-read' )         { $result = action_nav_read() }
elsif ( $action eq 'nav-save' )         {
    my $req = eval { decode_json($body) } // {};
    $result = action_nav_save( $req->{items} // [] );
}
elsif ( $action eq 'handler-list' )     { $result = action_handler_list() }
elsif ( $action eq 'handler-save' )     {
    my $req = eval { decode_json($body) } // {};
    $result = action_handler_save($req);
}
elsif ( $action eq 'handler-delete' )   {
    my $req = eval { decode_json($body) } // {};
    $result = action_handler_delete( $req->{id} );
}
elsif ( $action eq 'form-targets-read' ) {
    $result = action_form_targets_read( $params{form} );
}
elsif ( $action eq 'form-targets-save' ) {
    my $req = eval { decode_json($body) } // {};
    $result = action_form_targets_save( $params{form}, $req->{targets} // [] );
}
elsif ( $action eq 'file-upload' ) {
    $result = action_file_upload( $path, $body );
}
elsif ( $action eq 'file-download' ) {
    action_file_download($path);
    exit 0;
}
elsif ( $action eq 'file-zip-download' ) {
    action_file_zip_download();
    exit 0;
}
else  { $result = { ok => 0, error => "Unknown action: $action" } }

respond($result);

# --- M-1: CSRF helpers ---

# Shared secret for CSRF token HMAC. Reuses the auth secret if present,
# otherwise creates a dedicated manager secret under lazysite/auth/.
sub _csrf_secret {
    my $path = "$LAZYSITE_DIR/auth/.secret";
    if ( -f $path && open my $fh, '<', $path ) {
        chomp( my $s = <$fh> );
        close $fh;
        return $s if length $s;
    }
    # Dedicated manager secret (only used if auth secret missing)
    my $mpath = "$LAZYSITE_DIR/manager/.csrf-secret";
    if ( -f $mpath && open my $mfh, '<', $mpath ) {
        chomp( my $s = <$mfh> );
        close $mfh;
        return $s if length $s;
    }
    # Mint one - fail closed if CSPRNG unavailable (M-6).
    make_path( dirname($mpath) ) unless -d dirname($mpath);
    open my $rand, '<:raw', '/dev/urandom'
        or die "Cannot open /dev/urandom - no CSPRNG available: $!\n";
    my $raw = '';
    my $got = read( $rand, $raw, 32 );
    close $rand;
    die "Short read from /dev/urandom\n" unless $got == 32;
    my $s = unpack( 'H*', $raw );
    open my $wfh, '>', $mpath or die "Cannot write $mpath: $!\n";
    chmod 0o600, $mpath;
    print $wfh "$s\n";
    close $wfh;
    return $s;
}

sub generate_csrf_token {
    my ($user) = @_;
    my $ts = int( time() / 3600 );    # rotates hourly
    return hmac_sha256_hex( "csrf:$user:$ts", _csrf_secret() );
}

sub verify_csrf_token {
    my ( $token, $user ) = @_;
    return 0 unless defined $token && length $token;
    return 0 unless defined $user  && length $user;
    my $secret = _csrf_secret();
    for my $ts ( int( time() / 3600 ), int( time() / 3600 ) - 1 ) {
        my $expected = hmac_sha256_hex( "csrf:$user:$ts", $secret );
        return 1 if _const_eq( $token, $expected );
    }
    return 0;
}

sub _const_eq {
    my ( $a, $b ) = @_;
    return 0 unless defined $a && defined $b;
    return 0 if length($a) != length($b);
    my $r = 0;
    $r |= ord( substr( $a, $_, 1 ) ) ^ ord( substr( $b, $_, 1 ) )
        for 0 .. length($a) - 1;
    return $r == 0;
}

# --- Response ---

sub respond {
    my ($data) = @_;
    binmode( STDOUT, ':utf8' );
    print "Status: 200 OK\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n\r\n";
    print encode_json($data);
}

# --- Path validation ---

sub validate_path {
    my ($rel_path) = @_;
    return { ok => 0, error => "No path" } unless $rel_path;

    $rel_path =~ s{^/+}{};

    my $full = "$DOCROOT/$rel_path";
    my $check = -e $full ? $full : dirname($full);
    my $real = realpath($check);

    return { ok => 0, error => "Invalid path" }
        unless $real && index( $real, $DOCROOT ) == 0;

    return { ok => 1, full => $full, rel => $rel_path };
}

sub is_blocked_path {
    my ($rel_path) = @_;
    for my $blocked (@BLOCKED_PATHS) {
        if ( $rel_path eq $blocked ) {
            log_event('WARN', $action, 'blocked path access', path => $rel_path, user => $auth_user);
            return 1;
        }
    }
    if ( $rel_path =~ /\.pl$/ ) {
        log_event('WARN', $action, 'blocked path access', path => $rel_path, user => $auth_user);
        return 1;
    }
    return 0;
}

# SM020: every manager write path that previously did
# open/print/close had the same ENOSPC/EIO/quota blind spot.
# Centralised here so a future site gets the checked pattern by
# default. unlink-on-failure is deliberate: a half-written
# handlers.conf or nav.conf breaks every subsequent form
# submission or page render, which is worse than no file at all
# - the operator can restore from backup or re-save from the UI.
# Returns ($ok, $error_string). $! is captured into a lexical
# before close because close itself resets $!.
sub write_file_checked {
    my ( $path, $content ) = @_;
    open my $fh, '>:utf8', $path
        or return ( 0, "Cannot write file: $!" );
    unless ( print $fh $content ) {
        my $err = "$!";
        close $fh;
        unlink $path;
        return ( 0, "Write failed: $err" );
    }
    unless ( close $fh ) {
        my $err = "$!";
        unlink $path;
        return ( 0, "Close failed: $err" );
    }
    return ( 1, undef );
}

# --- Lock management ---

sub acquire_lock {
    my ( $rel_path, $username ) = @_;
    make_path($LOCK_DIR) unless -d $LOCK_DIR;

    my $lock_key = $rel_path;
    $lock_key =~ s{/}{:}g;
    my $lock_file = "$LOCK_DIR/$lock_key.lock";

    if ( -f $lock_file ) {
        open my $fh, '<', $lock_file or return { ok => 0, error => "Cannot read lock" };
        chomp( my $content = <$fh> );
        close $fh;
        my ( $locked_by, $locked_at ) = split /\s+/, $content, 2;
        my $age = time() - ( $locked_at // 0 );

        if ( $age < $LOCK_TIMEOUT && $locked_by ne $username ) {
            return {
                ok        => 0,
                locked    => 1,
                locked_by => $locked_by,
                locked_at => $locked_at,
                expires   => $locked_at + $LOCK_TIMEOUT,
            };
        }
    }

    open my $fh, '>', $lock_file or return { ok => 0, error => "Cannot write lock" };
    print $fh "$username " . time();
    close $fh;
    return { ok => 1, locked_by => $username };
}

sub release_lock {
    my ( $rel_path, $username ) = @_;
    my $lock_key = $rel_path;
    $lock_key =~ s{/}{:}g;
    my $lock_file = "$LOCK_DIR/$lock_key.lock";
    unlink $lock_file if -f $lock_file;
    return { ok => 1 };
}

sub renew_lock {
    my ( $rel_path, $username ) = @_;
    return acquire_lock( $rel_path, $username );
}

# --- File actions ---

sub action_list {
    my ($dir_path) = @_;
    $dir_path //= '/';
    $dir_path =~ s{[^a-zA-Z0-9/_.-]}{}g;
    # SM019c: collapse a trailing slash so child paths are assembled
    # as "/dir/name" not "/dir//name". The next line keeps "/" itself
    # intact because s{/+$}{}  on "/" yields "", which we re-inflate.
    $dir_path =~ s{/+$}{};
    $dir_path = '/' if $dir_path eq '';

    my $fs_path = "$DOCROOT$dir_path";
    my $real    = realpath($fs_path);
    return { ok => 0, error => "Invalid path" }
        unless $real && index( $real, $DOCROOT ) == 0 && -d $real;

    my @entries;
    opendir my $dh, $real or return { ok => 0, error => "Cannot read directory" };
    for my $name ( sort readdir $dh ) {
        next if $name =~ /^\./;
        my $full = "$real/$name";
        my $rel  = $dir_path eq '/' ? "/$name" : "$dir_path/$name";
        my @st   = stat($full);
        my $is_dir = -d $full ? 1 : 0;
        my $entry  = {
            name  => $name,
            path  => $rel,
            type  => $is_dir ? 'dir' : 'file',
            size  => $is_dir ? 0 : ( $st[7] // 0 ),
            mtime => $st[9] // 0,
        };
        # SM019b: surface emptiness so the client knows whether a
        # dir row should get a delete-selection checkbox. The check
        # matches action_delete's rmdir semantics: any non-dot
        # entry (including hidden files) counts as content. We
        # only count, never stat, so the cost scales with the
        # directory size, not tree depth.
        if ( $is_dir ) {
            if ( opendir my $dh2, $full ) {
                my @kids = grep { $_ ne '.' && $_ ne '..' } readdir $dh2;
                closedir $dh2;
                $entry->{empty} = @kids ? JSON::PP::false : JSON::PP::true;
            }
        }
        push @entries, $entry;
    }
    closedir $dh;

    return { ok => 1, path => $dir_path, entries => \@entries };
}

sub action_read {
    my ( $rel_path, $username ) = @_;

    my $result = validate_path($rel_path);
    return $result unless $result->{ok};

    return { ok => 0, error => "Path is blocked" }
        if is_blocked_path( $result->{rel} );

    my $full = $result->{full};
    return { ok => 0, error => "File not found" } unless -f $full;

    # SM019: refuse to load binary files as text. The editor handles
    # the binary=1 response by showing a download panel; decoding a
    # PNG as :utf8 here would otherwise emit replacement characters
    # and write the corrupted bytes back on save.
    unless ( is_editable_text( $result->{rel} ) ) {
        return {
            ok     => 0,
            binary => 1,
            path   => $rel_path,
            error  => "Binary file - download instead of edit",
        };
    }

    open my $fh, '<:utf8', $full or return { ok => 0, error => "Cannot read file" };
    my $content = do { local $/; <$fh> };
    close $fh;

    my $lock_info = _get_lock_info( $rel_path );

    return {
        ok      => 1,
        path    => $rel_path,
        content => $content,
        mtime   => ( stat $full )[9],
        lock    => $lock_info,
    };
}

sub action_save {
    my ( $rel_path, $username, $content, $mtime_check ) = @_;

    my $result = validate_path($rel_path);
    return $result unless $result->{ok};

    return { ok => 0, error => "Path is blocked" }
        if is_blocked_path( $result->{rel} );
    return { ok => 0, error => "Path is blocked by config" }
        if is_blocked_config( $result->{rel} );

    my $full = $result->{full};

    # Conflict check
    if ( -f $full && $mtime_check ) {
        my $current_mtime = ( stat $full )[9];
        if ( $current_mtime != $mtime_check ) {
            return {
                ok       => 0,
                conflict => 1,
                error    => "File was modified since you opened it",
                mtime    => $current_mtime,
            };
        }
    }

    # Lock check
    my $lock_key = $rel_path;
    $lock_key =~ s{/}{:}g;
    my $lock_file = "$LOCK_DIR/$lock_key.lock";
    if ( -f $lock_file ) {
        open my $lf, '<', $lock_file;
        chomp( my $lc = <$lf> );
        close $lf;
        my ( $by, $at ) = split /\s+/, $lc, 2;
        my $age = time() - ( $at // 0 );
        if ( $age < $LOCK_TIMEOUT && $by ne $username ) {
            return { ok => 0, error => "File is locked by $by" };
        }
    }

    # Create parent directories
    my $dir = dirname($full);
    make_path($dir) unless -d $dir;

    my ( $wok, $werr ) = write_file_checked( $full, $content );
    return { ok => 0, error => $werr } unless $wok;

    # Invalidate cache (only for .md files that have .html cache)
    if ( $full =~ /\.md$/ ) {
        ( my $cache = $full ) =~ s/\.md$/.html/;
        unlink $cache if -f $cache;
    }

    # Release lock
    unlink $lock_file if -f $lock_file;

    log_event('INFO', $action, 'file saved', path => $rel_path, user => $auth_user);

    my @st = stat($full);
    return { ok => 1, path => $rel_path, mtime => $st[9] // 0 };
}

sub action_delete {
    my ( $rel_path, $username ) = @_;

    my $result = validate_path($rel_path);
    return $result unless $result->{ok};

    return { ok => 0, error => "Path is blocked" }
        if is_blocked_path( $result->{rel} );
    return { ok => 0, error => "Path is blocked by config" }
        if is_blocked_config( $result->{rel} );

    my $full = $result->{full};

    # SM019b: empty directories are deletable from the manager.
    # Non-empty ones are rejected - no recursive delete.
    if ( -d $full ) {
        opendir my $dh, $full
            or return { ok => 0, error => "Cannot read directory: $!" };
        my @entries = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
        closedir $dh;
        if ( @entries ) {
            return { ok => 0, error => "Directory is not empty" };
        }
        rmdir $full
            or return { ok => 0, error => "Cannot remove directory: $!" };
        log_event('INFO', $action, 'directory deleted',
            path => $rel_path, user => $auth_user);
        return { ok => 1, path => $rel_path };
    }

    return { ok => 0, error => "File not found" } unless -f $full;

    unlink $full or return { ok => 0, error => "Cannot delete: $!" };

    ( my $cache = $full ) =~ s/\.md$/.html/;
    unlink $cache if -f $cache;

    log_event('INFO', $action, 'file deleted', path => $rel_path, user => $auth_user);

    return { ok => 1, path => $rel_path };
}

# SM019b: dedicated mkdir so "Add Folder" creates a genuinely empty
# directory. The previous files.md trick of writing /<name>/.gitkeep
# through action_save materialised the directory but left a hidden
# file inside, which conflicts with the new "empty dirs are
# deletable" rule - a freshly-created folder would not have a
# checkbox. Keeping this as a distinct action (rather than piggybacking
# on action_save with an empty body) also makes the log line clearer.
sub action_mkdir {
    my ($rel_path) = @_;

    my $result = validate_path($rel_path);
    return $result unless $result->{ok};

    return { ok => 0, error => "Path is blocked" }
        if is_blocked_path( $result->{rel} );
    return { ok => 0, error => "Path is blocked by config" }
        if is_blocked_config( $result->{rel} );

    my $full = $result->{full};
    return { ok => 0, error => "Path already exists" } if -e $full;

    make_path($full)
        or return { ok => 0, error => "Cannot create directory: $!" };

    log_event('INFO', $action, 'directory created',
        path => $rel_path, user => $auth_user);

    return { ok => 1, path => $rel_path };
}

sub action_preview {
    my ($rel_path) = @_;

    my $uri = $rel_path;
    $uri =~ s{^/*}{/};
    $uri =~ s/\.md$//;
    $uri =~ s{/index$}{/};

    local $ENV{LAZYSITE_NOCACHE}  = '1';
    local $ENV{REDIRECT_URL}      = $uri;
    local $ENV{DOCUMENT_ROOT}     = $DOCROOT;

    my $processor = "$DOCROOT/../cgi-bin/lazysite-processor.pl";
    $processor = $ENV{LAZYSITE_PROCESSOR} if $ENV{LAZYSITE_PROCESSOR};
    my $output = qx($^X \Q$processor\E 2>/dev/null);

    # Strip CGI headers
    $output =~ s/\A.*?\r?\n\r?\n//s;

    return { ok => 1, html => $output };
}

# --- Cache actions ---

sub action_cache_list {
    my @cached;
    find(
        sub {
            return unless /\.html$/;
            my $rel = $File::Find::name;
            $rel =~ s{^\Q$DOCROOT\E/?}{/};
            return if $rel =~ m{^/lazysite/};
            ( my $src = $File::Find::name ) =~ s/\.html$/.md/;
            push @cached, {
                path       => $rel,
                mtime      => ( stat $_ )[9],
                has_source => -f $src ? 1 : 0,
            };
        },
        $DOCROOT
    );
    return { ok => 1, cached => \@cached };
}

sub action_cache_invalidate {
    my ($rel_path) = @_;

    if ( $rel_path eq '*' ) {
        my $count = 0;
        find(
            sub {
                return unless /\.html$/;
                my $rel = $File::Find::name;
                $rel =~ s{^\Q$DOCROOT\E/?}{/};
                return if $rel =~ m{^/lazysite/};
                unlink $_;
                $count++;
            },
            $DOCROOT
        );
        return { ok => 1, count => $count };
    }

    my $full = "$DOCROOT$rel_path";
    $full =~ s/\.md$/.html/;
    $full .= '.html' unless $full =~ /\.html$/;

    my $real = realpath($full);
    return { ok => 0, error => "Invalid path" }
        unless $real && index( $real, $DOCROOT ) == 0;

    unlink $real if -f $real;
    log_event('INFO', $action, 'cache invalidated', path => $rel_path, user => $auth_user);
    return { ok => 1, path => $rel_path };
}

# --- Theme actions ---

sub action_theme_list {
    my $themes_dir = "$DOCROOT/lazysite/themes";
    my @themes;

    my $active = '';
    if ( open my $fh, '<', "$DOCROOT/lazysite/lazysite.conf" ) {
        while (<$fh>) { $active = $1 if /^theme\s*:\s*(\S+)/ }
        close $fh;
    }

    if ( -d $themes_dir ) {
        opendir( my $dh, $themes_dir );
        for my $name ( sort readdir $dh ) {
            next if $name =~ /^\./;
            next if $name eq 'manager';
            next unless -d "$themes_dir/$name";
            push @themes, {
                name   => $name,
                active => $name eq $active ? 1 : 0,
                valid  => -f "$themes_dir/$name/view.tt" ? 1 : 0,
            };
        }
        closedir $dh;
    }

    return { ok => 1, themes => \@themes, active => $active };
}

sub action_theme_activate {
    my ($theme_name) = @_;
    $theme_name =~ s/[^a-zA-Z0-9_-]//g;

    my $conf_path = "$DOCROOT/lazysite/lazysite.conf";
    return { ok => 0, error => "Cannot read conf" } unless -f $conf_path;

    open my $fh, '<:utf8', $conf_path or return { ok => 0, error => "Cannot read conf" };
    my $conf = do { local $/; <$fh> };
    close $fh;

    if ( $theme_name eq '' ) {
        # Deactivate - remove theme line
        $conf =~ s/^theme\s*:.*\n?//m;
    }
    elsif ( $conf =~ /^theme\s*:/m ) {
        $conf =~ s/^theme\s*:.*$/theme: $theme_name/m;
    }
    else {
        $conf .= "\ntheme: $theme_name\n";
    }

    open my $out, '>:utf8', $conf_path or return { ok => 0, error => "Cannot write conf" };
    print $out $conf;
    close $out;

    # Invalidate all cached pages
    find(
        sub {
            return unless /\.html$/;
            my $rel = $File::Find::name;
            $rel =~ s{^\Q$DOCROOT\E/?}{/};
            return if $rel =~ m{^/lazysite/};
            unlink $_;
        },
        $DOCROOT
    );

    return { ok => 1, theme => $theme_name };
}

sub action_theme_delete {
    my ($theme_name) = @_;
    $theme_name =~ s/[^a-zA-Z0-9_-]//g;

    my $active = '';
    if ( open my $fh, '<', "$DOCROOT/lazysite/lazysite.conf" ) {
        while (<$fh>) { $active = $1 if /^theme\s*:\s*(\S+)/ }
        close $fh;
    }
    return { ok => 0, error => "Cannot delete the active theme" }
        if $theme_name eq $active;

    my $theme_dir = "$DOCROOT/lazysite/themes/$theme_name";
    return { ok => 0, error => "Theme not found" } unless -d $theme_dir;

    my $real = realpath($theme_dir);
    return { ok => 0, error => "Invalid theme path" }
        unless $real && index( $real, "$DOCROOT/lazysite/themes" ) == 0;

    # M-3: inspect rm return code so partial failures surface to the caller.
    my $rc = system( "rm", "-rf", $theme_dir );
    if ( $rc != 0 ) {
        log_event('ERROR', 'theme-delete', 'rm failed',
            path => $theme_dir, rc => ( $rc >> 8 ));
        return { ok => 0, error => "Delete failed" };
    }
    my $assets_dir = "$DOCROOT/lazysite-assets/$theme_name";
    if ( -d $assets_dir ) {
        $rc = system( "rm", "-rf", $assets_dir );
        if ( $rc != 0 ) {
            log_event('WARN', 'theme-delete', 'rm assets failed',
                path => $assets_dir, rc => ( $rc >> 8 ));
        }
    }

    return { ok => 1, deleted => $theme_name };
}

sub action_theme_rename {
    my ( $old_name, $new_name ) = @_;
    $old_name =~ s/[^a-zA-Z0-9_-]//g;
    $new_name =~ s/[^a-zA-Z0-9_-]//g if defined $new_name;
    $new_name = lc( $new_name // '' );

    return { ok => 0, error => "Invalid name" } unless $old_name && $new_name;

    my $themes_dir = "$DOCROOT/lazysite/themes";
    return { ok => 0, error => "Theme not found" } unless -d "$themes_dir/$old_name";
    return { ok => 0, error => "Name already in use" } if -d "$themes_dir/$new_name";

    rename "$themes_dir/$old_name", "$themes_dir/$new_name";

    my $old_assets = "$DOCROOT/lazysite-assets/$old_name";
    my $new_assets = "$DOCROOT/lazysite-assets/$new_name";
    rename $old_assets, $new_assets if -d $old_assets;

    return { ok => 1, old => $old_name, new => $new_name };
}

sub action_theme_upload {
    my ( $zip_data, $filename ) = @_;

    # M-4: use Archive::Zip for safe extraction with per-entry path
    # validation, replacing system("unzip") which had to be trusted not
    # to zip-slip. Archive::Zip is an optional dep - install.sh warns if
    # missing, and this action returns a clear error instead of crashing.
    my $have_azip = eval { require Archive::Zip; Archive::Zip->import(qw(:ERROR_CODES)); 1 };
    unless ($have_azip) {
        return { ok => 0,
            error => "Archive::Zip not installed (apt-get install libarchive-zip-perl)" };
    }

    my $tmp_dir = "/tmp/lazysite-theme-$$";
    make_path($tmp_dir);

    my $zip_path = "$tmp_dir/upload.zip";
    open my $fh, '>:raw', $zip_path
        or do { _cleanup_tmp($tmp_dir); return { ok => 0, error => "Cannot write upload" } };
    print $fh $zip_data;
    close $fh;

    my $extract_dir = "$tmp_dir/extracted";
    make_path($extract_dir);

    my $extract_real = realpath($extract_dir);
    unless ( defined $extract_real ) {
        _cleanup_tmp($tmp_dir);
        return { ok => 0, error => "Cannot resolve extract dir" };
    }

    my $zip = Archive::Zip->new();
    unless ( $zip->read($zip_path) == Archive::Zip::AZ_OK() ) {
        _cleanup_tmp($tmp_dir);
        return { ok => 0, error => "Cannot read uploaded zip" };
    }

    # Validate every entry before extracting any.
    for my $member ( $zip->members ) {
        my $name = $member->fileName;
        if ( $name =~ m{\A/} ) {
            _cleanup_tmp($tmp_dir);
            return { ok => 0, error => "Zip entry has absolute path: $name" };
        }
        if ( $name =~ m{(?:^|/)\.\.(?:/|$)} ) {
            _cleanup_tmp($tmp_dir);
            return { ok => 0, error => "Zip slip detected in: $name" };
        }
    }

    # Extract with tree layout under $extract_dir. extractTree returns
    # AZ_OK on full success.
    unless ( $zip->extractTree( '', "$extract_dir/" ) == Archive::Zip::AZ_OK() ) {
        _cleanup_tmp($tmp_dir);
        return { ok => 0, error => "Extraction failed" };
    }

    unless ( -f "$extract_dir/view.tt" ) {
        _cleanup_tmp($tmp_dir);
        return { ok => 0, error => "Upload must contain view.tt" };
    }
    unless ( -f "$extract_dir/theme.json" ) {
        _cleanup_tmp($tmp_dir);
        return { ok => 0, error => "Upload must contain theme.json" };
    }

    open my $jf, '<:utf8', "$extract_dir/theme.json"
        or do { _cleanup_tmp($tmp_dir); return { ok => 0, error => "Cannot read theme.json" } };
    my $json = do { local $/; <$jf> };
    close $jf;
    my $meta = eval { decode_json($json) }
        or do { _cleanup_tmp($tmp_dir); return { ok => 0, error => "Invalid theme.json" } };

    my $theme_name = $meta->{name} // '';
    $theme_name =~ s/[^a-zA-Z0-9_-]//g;
    $theme_name = lc($theme_name);

    unless ($theme_name) {
        _cleanup_tmp($tmp_dir);
        return { ok => 0, error => "Invalid theme name in theme.json" };
    }

    my $install_name = $theme_name;
    my $themes_dir   = "$DOCROOT/lazysite/themes";
    if ( -d "$themes_dir/$theme_name" ) {
        my @t = localtime( time() );
        $install_name = sprintf( "%04d%02d%02d-%s",
            $t[5] + 1900, $t[4] + 1, $t[3], $theme_name );
    }

    my $dest = "$themes_dir/$install_name";
    make_path($dest);
    my $rc = system( "cp", "-r", "$extract_dir/.", $dest );
    if ( $rc != 0 ) {
        log_event('ERROR', 'theme-upload', 'cp failed',
            path => $dest, rc => ( $rc >> 8 ));
        _cleanup_tmp($tmp_dir);
        return { ok => 0, error => "Install failed (cp theme files)" };
    }

    if ( -d "$extract_dir/assets" ) {
        my $assets_dest = "$DOCROOT/lazysite-assets/$install_name";
        make_path($assets_dest);
        $rc = system( "cp", "-r", "$extract_dir/assets/.", $assets_dest );
        if ( $rc != 0 ) {
            log_event('WARN', 'theme-upload', 'cp assets failed',
                path => $assets_dest, rc => ( $rc >> 8 ));
        }
    }

    _cleanup_tmp($tmp_dir);

    log_event('INFO', $action, 'theme installed', name => $install_name, user => $auth_user);

    return { ok => 1, name => $install_name, installed_as => $install_name };
}

sub _cleanup_tmp {
    my ($dir) = @_;
    system( "rm", "-rf", $dir ) if $dir =~ m{^/tmp/lazysite-theme-\d+$};
}

# --- User management proxy ---

sub action_users {
    my ( $request_body, $params_ref ) = @_;

    my $users_script = dirname($0) . "/../tools/lazysite-users.pl";
    unless ( -f $users_script ) {
        $users_script = "$DOCROOT/../tools/lazysite-users.pl";
    }
    return { ok => 0, error => "User management not available" }
        unless -f $users_script;

    # The child (tools/lazysite-users.pl --api) always expects a single
    # JSON object on stdin. If we're hit with a plain GET (empty body),
    # pipe through a read-only request derived from the query string
    # rather than feeding the child an empty buffer and surfacing its
    # "Invalid JSON input" reply. Allowed GET sub-actions are list and
    # groups; writes (add / passwd / remove / group-add / group-remove)
    # must go via POST so they pass through the CSRF gate upstream.
    my $method = $ENV{REQUEST_METHOD} // 'GET';
    if ( $method ne 'POST' || !length $request_body ) {
        my $sub = ( $params_ref && $params_ref->{sub} ) || 'list';
        return { ok => 0, error => "Read-only sub-action on GET; allowed: list, groups" }
            unless $sub eq 'list' || $sub eq 'groups';
        $request_body = encode_json({ action => $sub });
    }

    my ( $child_out, $child_in );
    my $pid = eval {
        open2( $child_out, $child_in,
            $^X, $users_script, '--api', '--docroot', $DOCROOT );
    };
    return { ok => 0, error => "Cannot run user management: $@" } unless $pid;

    print $child_in $request_body;
    close $child_in;

    my $output = do { local $/; <$child_out> };
    close $child_out;
    waitpid $pid, 0;

    return eval { decode_json( $output // '{}' ) } // { ok => 0, error => "Invalid response" };
}

# Rotate the per-installation HMAC secret in lazysite/auth/.secret.
# Every existing auth cookie is signed with the previous secret, so
# rewriting this file invalidates every outstanding session (the
# operator's own session included). This is the "log everyone out"
# lever - the server-side mitigation for the known "no session
# revocation" constraint.
sub action_rotate_auth_secret {
    my ($auth_user) = @_;
    my $path = "$LAZYSITE_DIR/auth/.secret";

    # Fail closed if CSPRNG unavailable (M-6 convention)
    open my $rand, '<:raw', '/dev/urandom'
        or return { ok => 0, error => "Cannot open /dev/urandom: $!" };
    my $raw = '';
    my $got = read( $rand, $raw, 32 );
    close $rand;
    return { ok => 0, error => "Short read from /dev/urandom ($got of 32)" }
        unless defined $got && $got == 32;
    my $new = unpack( 'H*', $raw );

    make_path( dirname($path) ) unless -d dirname($path);

    # Atomic write: tempfile + rename. If anything in the chain fails,
    # the original .secret keeps working - we never leave the file
    # empty or partial, which would lock everyone out without giving
    # them a way back in.
    my $tmp = "$path.tmp.$$";
    open my $wfh, '>', $tmp
        or return { ok => 0, error => "Cannot write $tmp: $!" };
    chmod 0o600, $tmp;
    print $wfh "$new\n";
    close $wfh;
    unless ( rename $tmp, $path ) {
        my $err = $!;
        unlink $tmp;
        return { ok => 0, error => "Cannot replace $path: $err" };
    }
    chmod 0o600, $path;

    # Also clear the CSRF secret cache file (if dedicated one exists).
    # The CSRF helper falls back to .secret, so the new .secret
    # becomes the new CSRF secret too - but the operator's next POST
    # will race with their about-to-expire session cookie, so bail
    # out cleanly by cycling them through /login.
    my $csrf_secret = "$LAZYSITE_DIR/manager/.csrf-secret";
    unlink $csrf_secret if -f $csrf_secret;

    log_event( 'WARN', $auth_user,
        'auth secret rotated - all sessions invalidated' );

    return {
        ok      => 1,
        message => 'All sessions invalidated. You will need to sign in again.',
    };
}

# --- Helpers ---

# --- Plugin actions ---

sub resolve_plugin_script {
    my ($script) = @_;
    return unless $script;
    # Check relative to docroot parent (installed layout)
    my $full = "$DOCROOT/../$script";
    return $full if -f $full;
    # Check relative to docroot
    $full = "$DOCROOT/$script";
    return $full if -f $full;
    # Check basename at docroot parent (dev mode - scripts at repo root)
    my $base = basename($script);
    $full = "$DOCROOT/../$base";
    return $full if -f $full;
    return;
}

# --- Nav actions ---

sub _nav_conf_path {
    # Read nav_file from lazysite.conf, default to lazysite/nav.conf
    my $nav_file = 'lazysite/nav.conf';
    my $conf = "$DOCROOT/lazysite/lazysite.conf";
    if ( -f $conf ) {
        open my $fh, '<:utf8', $conf;
        while (<$fh>) {
            if ( /^nav_file\s*:\s*(.+)/ ) {
                $nav_file = $1;
                $nav_file =~ s/^\s+|\s+$//g;
                last;
            }
        }
        close $fh;
    }
    return "$DOCROOT/$nav_file";
}

sub action_nav_read {
    my $path = _nav_conf_path();
    my @items;

    if ( -f $path ) {
        open my $fh, '<:utf8', $path or return { ok => 0, error => "Cannot read nav" };
        my $current_parent = -1;
        while (<$fh>) {
            chomp;
            next if /^\s*#/ || /^\s*$/;

            my $is_child = /^\s+/;
            s/^\s+|\s+$//g;

            my ( $label, $url ) = split /\s*\|\s*/, $_, 2;
            $label //= '';
            $url   //= '';
            $label =~ s/^\s+|\s+$//g;
            $url   =~ s/^\s+|\s+$//g;
            next unless length $label;

            if ($is_child && $current_parent >= 0) {
                push @{ $items[$current_parent]{children} },
                    { label => $label, url => $url };
            } else {
                push @items, { label => $label, url => $url, children => [] };
                $current_parent = $#items;
            }
        }
        close $fh;
    }

    return { ok => 1, items => \@items, path => $path };
}

sub action_nav_save {
    my ($items) = @_;
    my $path = _nav_conf_path();

    my $content = "# lazysite navigation\n";
    $content .= "# Format: Label | /url\n";
    $content .= "# Indent child items with any whitespace\n\n";

    for my $item ( @$items ) {
        my $label = $item->{label} // '';
        my $url   = $item->{url}   // '';
        $label =~ s/^\s+|\s+$//g;
        $url   =~ s/^\s+|\s+$//g;
        next unless length $label;

        if ( length $url ) {
            $content .= "$label | $url\n";
        } else {
            $content .= "$label\n";
        }

        for my $child ( @{ $item->{children} // [] } ) {
            my $cl = $child->{label} // '';
            my $cu = $child->{url}   // '';
            $cl =~ s/^\s+|\s+$//g;
            $cu =~ s/^\s+|\s+$//g;
            next unless length $cl;
            $content .= "  $cl | $cu\n";
        }
    }

    my $dir = dirname($path);
    make_path($dir) unless -d $dir;
    my ( $wok, $werr ) = write_file_checked( $path, $content );
    return { ok => 0, error => "Cannot write nav: $werr" } unless $wok;

    return { ok => 1 };
}

sub action_plugin_list {
    my $cache_file = "$DOCROOT/lazysite/cache/plugin-list.cache";
    if ( -f $cache_file && (time() - (stat($cache_file))[9]) < 60 ) {
        open my $fh, '<', $cache_file or return { ok=>0, error=>"cache read failed" };
        my $data = do { local $/; <$fh> }; close $fh;
        my $parsed = eval { decode_json($data) };
        return $parsed if $parsed && $parsed->{ok};
    }

    my %enabled;
    my $conf_path = "$DOCROOT/lazysite/lazysite.conf";
    if ( open my $fh, '<:utf8', $conf_path ) {
        my $in_plugins = 0;
        while (<$fh>) {
            chomp;
            if (/^plugins\s*:\s*$/) { $in_plugins = 1; next }
            if ($in_plugins && /^\s+-\s+(.+)$/) {
                my $entry = $1;
                $entry =~ s/\s+$//;
                $enabled{$entry} = 1;
            }
            elsif ($in_plugins && !/^\s/) { $in_plugins = 0 }
        }
        close $fh;
    }

    my @CANDIDATES = (
        'lazysite-auth.pl',
        'lazysite-form-handler.pl',
        'lazysite-form-smtp.pl',
        'lazysite-payment-demo.pl',
        'lazysite-log.pl',
        'tools/lazysite-audit.pl',
    );

    my $base = Cwd::realpath("$DOCROOT/..");
    my @plugins;

    for my $rel ( @CANDIDATES ) {
        my $full = "$base/$rel";
        next unless -f $full && -r $full;

        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(2);
        my $json = eval { qx($^X \Q$full\E --describe 2>/dev/null) };
        alarm(0);
        next if $@ || !$json;

        my $desc = eval { decode_json($json) };
        next unless $desc && ref $desc eq 'HASH' && $desc->{id};

        $desc->{_script}  = $rel;
        $desc->{_enabled} = $enabled{$rel} ? JSON::PP::true : JSON::PP::false;

        push @plugins, $desc;
    }

    @plugins = sort {
        ($b->{_enabled} ? 1 : 0) <=> ($a->{_enabled} ? 1 : 0)
            || ($a->{name} // '') cmp ($b->{name} // '')
    } @plugins;

    my $cache_dir = dirname($cache_file);
    make_path($cache_dir) unless -d $cache_dir;
    if ( open my $fh, '>', $cache_file ) {
        print $fh encode_json({ ok => 1, plugins => \@plugins });
        close $fh;
    }

    return { ok => 1, plugins => \@plugins };
}

sub action_plugin_enable {
    my ($script) = @_;
    $script =~ s/[^a-zA-Z0-9_.\/\-]//g;
    return { ok => 0, error => 'No script' } unless $script;
    return _update_plugins_conf($script, 'add');
}

sub action_plugin_disable {
    my ($script) = @_;
    $script =~ s/[^a-zA-Z0-9_.\/\-]//g;
    return { ok => 0, error => 'No script' } unless $script;
    return _update_plugins_conf($script, 'remove');
}

sub _update_plugins_conf {
    my ($script, $op) = @_;

    my $conf_path = "$DOCROOT/lazysite/lazysite.conf";
    open my $fh, '<:utf8', $conf_path
        or return { ok => 0, error => "Cannot read lazysite.conf" };
    my $conf = do { local $/; <$fh> };
    close $fh;

    my @lines   = split /\n/, $conf;
    my @plugins;
    my $in_plugins = 0;
    my $found_block = 0;
    my @before;
    my @after;
    my $phase = 'before';

    for my $line (@lines) {
        if ( $line =~ /^plugins\s*:\s*$/ ) {
            $in_plugins = 1;
            $found_block = 1;
            $phase = 'plugins';
            next;
        }
        if ( $in_plugins ) {
            if ( $line =~ /^\s+-\s+(.+)$/ ) {
                my $entry = $1;
                $entry =~ s/\s+$//;
                push @plugins, $entry;
                next;
            }
            elsif ( $line !~ /^\s/ ) {
                $in_plugins = 0;
                $phase = 'after';
            }
            else { next }
        }
        if    ( $phase eq 'before' ) { push @before, $line }
        elsif ( $phase eq 'after' )  { push @after, $line }
    }

    if ( $op eq 'add' ) {
        push @plugins, $script unless grep { $_ eq $script } @plugins;
    }
    elsif ( $op eq 'remove' ) {
        @plugins = grep { $_ ne $script } @plugins;
    }

    my $new_conf = join("\n", @before);
    if ( @plugins ) {
        $new_conf .= "\nplugins:\n";
        $new_conf .= "  - $_\n" for @plugins;
    }
    $new_conf .= join("\n", @after) if @after;
    $new_conf =~ s/\n{3,}/\n\n/g;
    $new_conf .= "\n" unless $new_conf =~ /\n$/;

    my ( $wok, $werr ) = write_file_checked( $conf_path, $new_conf );
    return { ok => 0, error => "Cannot write lazysite.conf: $werr" }
        unless $wok;

    unlink "$DOCROOT/lazysite/cache/plugin-list.cache";

    return { ok => 1, action => $op, script => $script };
}

sub action_plugin_read {
    my ( $plugin_id, $script ) = @_;

    my $full_script = resolve_plugin_script($script);
    return { ok => 0, error => 'Plugin not found' } unless $full_script;

    my $json = qx($^X \Q$full_script\E --describe 2>/dev/null);
    my $desc = eval { decode_json($json) }
        or return { ok => 0, error => 'Cannot describe plugin' };

    my $config_file = $desc->{config_file} // '';
    my %values;

    if ($config_file) {
        my $conf_path = "$DOCROOT/$config_file";
        if ( -f $conf_path ) {
            open my $fh, '<:utf8', $conf_path;
            while (<$fh>) {
                chomp;
                s/^\s+|\s+$//g;
                next if /^#/ || !length;
                my ( $k, $v ) = split /\s*:\s*/, $_, 2;
                $values{$k} = $v if defined $k && defined $v;
            }
            close $fh;
        }
    }
    elsif ( $desc->{config_keys} ) {
        my %want = map { $_ => 1 } @{ $desc->{config_keys} };
        my $conf_path = "$DOCROOT/lazysite/lazysite.conf";
        if ( -f $conf_path ) {
            open my $fh, '<:utf8', $conf_path;
            while (<$fh>) {
                chomp;
                s/^\s+|\s+$//g;
                next if /^#/ || !length;
                my ( $k, $v ) = split /\s*:\s*/, $_, 2;
                $values{$k} = $v if $want{$k};
            }
            close $fh;
        }
    }

    # Never return password fields
    for my $field ( @{ $desc->{config_schema} // [] } ) {
        delete $values{ $field->{key} } if ( $field->{type} // '' ) eq 'password';
    }

    return { ok => 1, values => \%values };
}

sub action_plugin_save {
    my ( $plugin_id, $script, $values ) = @_;

    my $full_script = resolve_plugin_script($script);
    return { ok => 0, error => 'Plugin not found' } unless $full_script;

    my $json = qx($^X \Q$full_script\E --describe 2>/dev/null);
    my $desc = eval { decode_json($json) }
        or return { ok => 0, error => 'Cannot describe plugin' };

    my %allowed = map { $_->{key} => 1 } @{ $desc->{config_schema} // [] };
    my %safe;
    for my $k ( keys %$values ) {
        $safe{$k} = $values->{$k} if $allowed{$k};
    }

    my $config_file = $desc->{config_file} // '';

    if ($config_file) {
        my $conf_path = "$DOCROOT/$config_file";
        my $content   = '';
        if ( -f $conf_path ) {
            open my $fh, '<:utf8', $conf_path;
            $content = do { local $/; <$fh> };
            close $fh;
        }

        for my $k ( keys %safe ) {
            if ( $content =~ /^$k\s*:/m ) {
                $content =~ s/^$k\s*:.*$/$k: $safe{$k}/m;
            }
            else {
                $content .= "$k: $safe{$k}\n";
            }
        }

        my $dir = dirname($conf_path);
        make_path($dir) unless -d $dir;
        my ( $wok, $werr ) = write_file_checked( $conf_path, $content );
        return { ok => 0, error => "Cannot write config: $werr" }
            unless $wok;
    }
    elsif ( $desc->{config_keys} ) {
        my %want = map { $_ => 1 } @{ $desc->{config_keys} };
        my $conf_path = "$DOCROOT/lazysite/lazysite.conf";
        my $content   = '';
        if ( -f $conf_path ) {
            open my $fh, '<:utf8', $conf_path;
            $content = do { local $/; <$fh> };
            close $fh;
        }

        for my $k ( grep { $want{$_} } keys %safe ) {
            if ( $content =~ /^$k\s*:/m ) {
                $content =~ s/^$k\s*:.*$/$k: $safe{$k}/m;
            }
            else {
                $content .= "$k: $safe{$k}\n";
            }
        }

        my ( $wok, $werr ) = write_file_checked( $conf_path, $content );
        return { ok => 0, error => "Cannot write lazysite.conf: $werr" }
            unless $wok;
    }

    return { ok => 1 };
}

sub action_plugin_action {
    my ( $plugin_id, $script, $action_id ) = @_;

    my $full_script = resolve_plugin_script($script);
    return { ok => 0, error => 'Plugin not found' } unless $full_script;

    my $json = qx($^X \Q$full_script\E --describe 2>/dev/null);
    my $desc = eval { decode_json($json) }
        or return { ok => 0, error => 'Cannot describe plugin' };

    my ($action) = grep { $_->{id} eq $action_id } @{ $desc->{actions} // [] };
    return { ok => 0, error => 'Action not found' } unless $action;

    if ( $action->{link} ) {
        return { ok => 1, link => $action->{link} };
    }

    my $output = qx($^X \Q$full_script\E --scan --docroot \Q$DOCROOT\E 2>/dev/null);
    my $result = eval { decode_json($output) }
        // { ok => 0, error => 'Action produced no output' };

    return $result;
}

# --- Handler actions ---

sub _handlers_conf_path {
    return "$DOCROOT/lazysite/forms/handlers.conf";
}

sub _parse_handlers_conf {
    my $path = _handlers_conf_path();
    return [] unless -f $path;

    open my $fh, '<:utf8', $path or return [];
    my $text = do { local $/; <$fh> };
    close $fh;

    my @handlers;
    while ( $text =~ /^\s{2}-\s+id:\s*(\S+)(.*?)(?=^\s{2}-\s+id:|\z)/gmsx ) {
        my ( $id, $block ) = ( $1, $2 );
        my %h = ( id => $id );
        while ( $block =~ /^\s{4}(\w+)\s*:\s*(.+)$/mg ) {
            my ( $k, $v ) = ( $1, $2 );
            $v =~ s/\s+$//;
            $h{$k} = $v;
        }
        push @handlers, \%h;
    }
    return \@handlers;
}

sub _write_handlers_conf {
    my ($handlers) = @_;
    my $path = _handlers_conf_path();

    my $dir = dirname($path);
    make_path($dir) unless -d $dir;

    my $content = "# Form dispatch handlers\n";
    $content .= "# Add handlers here and reference them from form .conf files\n\n";
    $content .= "handlers:\n";

    for my $h (@$handlers) {
        $content .= "  - id: $h->{id}\n";
        for my $k ( sort keys %$h ) {
            next if $k eq 'id';
            $content .= "    $k: $h->{$k}\n";
        }
    }

    my ( $wok ) = write_file_checked( $path, $content );
    return $wok;
}

sub action_handler_list {
    my $handlers = _parse_handlers_conf();
    return { ok => 1, handlers => $handlers };
}

sub action_handler_save {
    my ($data) = @_;
    my $id = $data->{id} // '';
    $id =~ s/[^a-zA-Z0-9_-]//g;
    return { ok => 0, error => "Invalid handler ID" } unless $id;

    my $handlers = _parse_handlers_conf();

    # Build handler record from input
    my %new = ( id => $id );
    for my $k (qw(type name enabled from to subject_prefix path url format
                   method sendmail_path host port tls auth username password_file)) {
        $new{$k} = $data->{$k} if defined $data->{$k} && length $data->{$k};
    }
    $new{type} //= 'file';

    # Replace existing or append
    my $found = 0;
    for my $h (@$handlers) {
        if ( $h->{id} eq $id ) {
            %$h = %new;
            $found = 1;
            last;
        }
    }
    push @$handlers, \%new unless $found;

    _write_handlers_conf($handlers)
        or return { ok => 0, error => "Cannot write handlers.conf" };

    return { ok => 1, id => $id };
}

sub action_handler_delete {
    my ($id) = @_;
    return { ok => 0, error => "No handler ID" } unless $id;

    my $handlers = _parse_handlers_conf();
    my @filtered = grep { $_->{id} ne $id } @$handlers;

    if ( scalar @filtered == scalar @$handlers ) {
        return { ok => 0, error => "Handler not found: $id" };
    }

    _write_handlers_conf(\@filtered)
        or return { ok => 0, error => "Cannot write handlers.conf" };

    return { ok => 1, deleted => $id };
}

sub action_form_targets_read {
    my ($form_name) = @_;
    $form_name //= '';
    $form_name =~ s/[^a-zA-Z0-9_-]//g;
    return { ok => 0, error => "Invalid form name" } unless $form_name;

    my $path = "$DOCROOT/lazysite/forms/$form_name.conf";
    return { ok => 1, targets => [] } unless -f $path;

    open my $fh, '<:utf8', $path or return { ok => 0, error => "Cannot read form config" };
    my $text = do { local $/; <$fh> };
    close $fh;

    my @targets;

    # New format: handler references
    while ( $text =~ /^\s*-\s+handler:\s*(\S+)/mg ) {
        push @targets, { handler => $1 };
    }

    # Legacy format: inline type config
    if ( !@targets ) {
        while ( $text =~ /^\s*-\s+type:\s*(\w+)\s*$(.*?)(?=^\s*-\s+type:|\z)/gms ) {
            my ( $type, $block ) = ( $1, $2 );
            my %t = ( type => $type );
            $t{url}    = $1 if $block =~ /^\s*url:\s*(.+)$/m;
            $t{format} = $1 if $block =~ /^\s*format:\s*(.+)$/m;
            $t{path}   = $1 if $block =~ /^\s*path:\s*(.+)$/m;
            $t{$_} =~ s/^\s+|\s+$//g for grep { defined $t{$_} } keys %t;
            push @targets, \%t;
        }
    }

    return { ok => 1, form => $form_name, targets => \@targets };
}

sub action_form_targets_save {
    my ( $form_name, $targets ) = @_;
    $form_name //= '';
    $form_name =~ s/[^a-zA-Z0-9_-]//g;
    return { ok => 0, error => "Invalid form name" } unless $form_name;

    my $path = "$DOCROOT/lazysite/forms/$form_name.conf";
    my $dir  = dirname($path);
    make_path($dir) unless -d $dir;

    my $content = "targets:\n";
    for my $t (@$targets) {
        if ( $t->{handler} ) {
            $content .= "  - handler: $t->{handler}\n";
        }
        else {
            my $type = $t->{type} // 'file';
            $content .= "  - type: $type\n";
            for my $k (qw(url format path)) {
                $content .= "    $k: $t->{$k}\n" if defined $t->{$k} && length $t->{$k};
            }
        }
    }

    my ( $wok, $werr ) = write_file_checked( $path, $content );
    return { ok => 0, error => "Cannot write form config: $werr" }
        unless $wok;

    return { ok => 1, form => $form_name };
}

# --- SM019: upload / download / zip-download ---

# Read the manager_upload_* / manager_blocked_* keys from
# lazysite.conf. All are optional; invalid values fall back to
# the hard-coded defaults and are logged at WARN. Called once
# per request via upload_limits().
#
# SM019c renamed manager_upload_blocked_paths to
# manager_blocked_paths because the list now gates download,
# save, and delete as well as upload. The old key is still
# accepted with a one-time INFO log so operators have a chance
# to update their conf on the next restart.
sub load_upload_limits {
    my %limits = (
        max_bytes          => 10 * 1024 * 1024,
        blocked_paths      => [ qw(
            lazysite/auth lazysite/forms lazysite/cache
            lazysite/themes/manager cgi-bin manager
        ) ],
        blocked_extensions => [ qw(pl cgi) ],
        rate_count         => 60,
        rate_bytes         => 500 * 1024 * 1024,
    );

    my $conf_path = "$DOCROOT/lazysite/lazysite.conf";
    return \%limits unless -f $conf_path;

    my $new_key_seen = 0;
    my $old_key_seen = 0;
    open my $fh, '<', $conf_path or return \%limits;
    while (<$fh>) {
        if ( /^manager_upload_max_mb\s*:\s*(\S+)/ ) {
            my $mb = $1;
            if ( $mb =~ /^\d+$/ && $mb > 0 ) {
                $limits{max_bytes} = $mb * 1024 * 1024;
            } else {
                log_event( 'WARN', 'config',
                    'invalid manager_upload_max_mb', value => $mb );
            }
        }
        elsif ( /^manager_blocked_paths\s*:\s*(.+)/ ) {
            my $v = $1;
            $v =~ s/\s+$//;
            if ( length $v ) {
                $limits{blocked_paths} = [
                    map  { my $p = $_; $p =~ s{^/+|/+$}{}g; $p }
                    grep { length }
                    split /\s*,\s*/, $v
                ];
            }
            $new_key_seen = 1;
        }
        elsif ( /^manager_upload_blocked_paths\s*:\s*(.+)/ ) {
            # Deprecated alias; only honoured if the new key
            # is absent. The new-key check happens after the
            # loop because they may appear in either order.
            my $v = $1;
            $v =~ s/\s+$//;
            if ( length $v ) {
                $limits{_deprecated_blocked_paths} = [
                    map  { my $p = $_; $p =~ s{^/+|/+$}{}g; $p }
                    grep { length }
                    split /\s*,\s*/, $v
                ];
            }
            $old_key_seen = 1;
        }
        elsif ( /^manager_upload_blocked_extensions\s*:\s*(.+)/ ) {
            my $v = $1;
            $v =~ s/\s+$//;
            if ( length $v ) {
                $limits{blocked_extensions} = [
                    map  { lc $_ }
                    grep { length }
                    split /\s*,\s*/, $v
                ];
            }
        }
        elsif ( /^manager_upload_rate_count\s*:\s*(\S+)/ ) {
            my $n = $1;
            if ( $n =~ /^\d+$/ ) {
                $limits{rate_count} = $n + 0;
            } else {
                log_event( 'WARN', 'config',
                    'invalid manager_upload_rate_count', value => $n );
            }
        }
        elsif ( /^manager_upload_rate_mb\s*:\s*(\S+)/ ) {
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

my $_upload_limits_cache;
sub upload_limits {
    $_upload_limits_cache //= load_upload_limits();
    return $_upload_limits_cache;
}

# Reset hook used by tests that rewrite the conf between calls. Not
# referenced from production code paths; CGI processes are one-shot.
sub _reset_upload_limits_cache { $_upload_limits_cache = undef }

# Second gate on top of is_blocked_path. is_blocked_path enforces a
# hard-coded list plus the .pl rule; this one reads the configurable
# blocked_paths and (for uploads only) blocked_extensions lists.
#
# SM019c widened the caller set: the path list now gates save,
# delete, download, zip-download, and upload. The extension list
# is still upload-only (no reason to block a user from downloading
# a .pl they already created through other means). The
# $check_extensions flag controls that.
sub is_blocked_config {
    my ( $rel_path, $check_extensions ) = @_;
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

# SM019c: kept as a thin compat shim so callers (and tests)
# written against the SM019 name still work. New call sites
# should use is_blocked_config directly.
sub is_blocked_upload_target {
    my ($rel_path) = @_;
    return is_blocked_config( $rel_path, 1 );
}

# Per-user hourly budget on upload count and total bytes. Mirrors the
# .login-rate.db pattern in lazysite-auth.pl: fail-open on DB failure,
# reserve budget up-front from CONTENT_LENGTH, age out stale buckets
# opportunistically. Returns { ok => 1 } or { ok => 0, error => ... }.
sub check_upload_rate {
    my ( $username, $content_length ) = @_;
    my $limits = upload_limits();

    return { ok => 1 }
        if $limits->{rate_count} == 0
        && $limits->{rate_bytes} == 0;

    my $rate_dir  = "$LAZYSITE_DIR/manager";
    my $rate_path = "$rate_dir/.upload-rate.db";
    make_path($rate_dir) unless -d $rate_dir;

    my %db;
    # Note: no assignment of the tie return value - holding a
    # reference to the tied object would trigger "untie attempted
    # while inner references still exist" on the untie below.
    eval { require DB_File; 1 } or do {
        log_event( 'WARN', 'file-upload', 'rate DB tie failed',
            path => $rate_path, error => "DB_File unavailable: $@" );
        return { ok => 1 };
    };
    eval {
        no warnings 'once';
        tie %db, 'DB_File', $rate_path, O_RDWR | O_CREAT, 0o600,
            $DB_File::DB_HASH;
    };
    unless ( tied %db ) {
        log_event( 'WARN', 'file-upload', 'rate DB tie failed',
            path => $rate_path, error => ( $@ || 'tie returned empty' ) );
        return { ok => 1 };    # fail open
    }

    my $hour       = int( time() / 3600 );
    my $count_key  = "$username:$hour:count";
    my $bytes_key  = "$username:$hour:bytes";

    my $cur_count  = $db{$count_key} || 0;
    my $cur_bytes  = $db{$bytes_key} || 0;

    if ( $limits->{rate_count} > 0
        && $cur_count >= $limits->{rate_count} ) {
        untie %db;
        log_event( 'WARN', 'file-upload',
            'rate limit exceeded (count)',
            user => $username, hour => $hour,
            count => $cur_count, limit => $limits->{rate_count} );
        return { ok => 0,
            error => "Upload rate limit reached "
                   . "($limits->{rate_count} per hour)" };
    }

    if ( $limits->{rate_bytes} > 0
        && $cur_bytes + $content_length > $limits->{rate_bytes} ) {
        untie %db;
        log_event( 'WARN', 'file-upload',
            'rate limit exceeded (bytes)',
            user => $username, hour => $hour,
            bytes => $cur_bytes, limit => $limits->{rate_bytes},
            requested => $content_length );
        return { ok => 0,
            error => "Upload size limit reached for this hour" };
    }

    # Reserve up-front. CONTENT_LENGTH includes multipart overhead so
    # this slightly over-counts, which is the safe direction. Counted
    # per request, not per file: a ten-file upload in one request
    # costs one count slot.
    $db{$count_key} = $cur_count + 1;
    $db{$bytes_key} = $cur_bytes + $content_length;

    for my $k ( keys %db ) {
        if ( $k =~ /:(\d+):/ ) {
            delete $db{$k} if $1 < $hour - 1;
        }
    }

    untie %db;
    return { ok => 1 };
}

sub parse_multipart_body {
    my ( $body, $content_type ) = @_;

    my ($q_boundary, $u_boundary) = $content_type =~
        m{multipart/form-data.*?boundary=(?:"([^"]+)"|([^;\s]+))}i;
    my $boundary = $q_boundary // $u_boundary // '';
    return () unless length $boundary;

    my @parts;
    # Relies on well-formed boundaries - a boundary string appearing
    # inside a payload would corrupt parsing. This is the documented
    # multipart assumption; browsers pick random-looking boundaries
    # that make collision vanishingly unlikely.
    for my $chunk ( split /--\Q$boundary\E(?:--)?\r?\n?/, $body ) {
        next unless length $chunk;
        next unless $chunk =~ /\r?\n\r?\n/;

        my ( $headers, $content ) = split /\r?\n\r?\n/, $chunk, 2;
        next unless defined $content;

        $content =~ s/\r?\n\z//;

        my %part;
        if ( $headers =~ /Content-Disposition:\s*[^;]+;(.+)/i ) {
            my $disp = $1;
            ( $part{name} )     = $disp =~ /\bname="([^"]*)"/;
            ( $part{filename} ) = $disp =~ /\bfilename="([^"]*)"/;
        }
        if ( $headers =~ /Content-Type:\s*(\S+)/i ) {
            $part{type} = $1;
        }
        $part{data} = $content;
        push @parts, \%part if defined $part{name};
    }
    return @parts;
}

sub sanitise_upload_filename {
    my ($name) = @_;
    return '' unless defined $name;
    $name =~ s{.*[/\\]}{};             # basename only
    return '' if $name =~ /\0/;        # null bytes
    return '' if $name eq '' || $name eq '.' || $name eq '..';
    $name =~ s/[\x00-\x1f]//g;         # strip control chars
    return $name;
}

sub action_file_upload {
    my ( $rel_dir, $body ) = @_;

    my $ctype = $ENV{CONTENT_TYPE} // '';
    unless ( $ctype =~ m{^multipart/form-data}i ) {
        return { ok => 0, error => "Expected multipart body" };
    }

    $rel_dir //= '/';
    $rel_dir =~ s{^/+}{};
    $rel_dir =~ s{/+$}{};
    my $full_dir = length $rel_dir ? "$DOCROOT/$rel_dir" : $DOCROOT;

    unless ( -d $full_dir ) {
        return { ok => 0, error => "Target is not a directory" };
    }
    my $real = realpath($full_dir);
    unless ( $real && index( $real, $DOCROOT ) == 0 ) {
        return { ok => 0, error => "Invalid target directory" };
    }

    my @parts = parse_multipart_body( $body, $ctype );
    my @files = grep { defined $_->{filename}
                        && length $_->{filename} } @parts;

    unless (@files) {
        return { ok => 0, error => "No files in upload" };
    }

    my $overwrite = 0;
    for my $p (@parts) {
        if ( ( $p->{name} // '' ) eq 'overwrite'
            && ( $p->{data} // '' ) eq '1' ) {
            $overwrite = 1;
        }
    }

    my @saved;
    my @skipped;
    my @errors;

    for my $file (@files) {
        my $fname = sanitise_upload_filename( $file->{filename} );
        unless ( length $fname ) {
            push @errors, { name => $file->{filename},
                            error => 'Invalid filename' };
            next;
        }

        my $rel_target = length $rel_dir
            ? "$rel_dir/$fname"
            : $fname;

        if ( is_blocked_path($rel_target)
            || is_blocked_config( $rel_target, 1 ) ) {
            push @errors, { name => $fname,
                            error => 'Blocked target' };
            next;
        }

        my $full_target = "$DOCROOT/$rel_target";

        if ( -e $full_target && !$overwrite ) {
            push @skipped, $fname;
            next;
        }

        my $tmp = "$full_target.tmp.$$";
        unless ( open my $fh, '>', $tmp ) {
            push @errors, { name => $fname,
                            error => "Cannot write: $!" };
            next;
        }
        else {
            binmode $fh;
            unless ( print {$fh} $file->{data} ) {
                my $err = "$!";
                close $fh;
                unlink $tmp;
                push @errors, { name => $fname,
                                error => "Write failed: $err" };
                next;
            }
            unless ( close $fh ) {
                my $err = "$!";
                unlink $tmp;
                push @errors, { name => $fname,
                                error => "Close failed: $err" };
                next;
            }
        }

        unless ( rename $tmp, $full_target ) {
            my $err = "$!";
            unlink $tmp;
            push @errors, { name => $fname,
                            error => "Cannot rename: $err" };
            next;
        }

        my @st = stat $full_target;
        push @saved, {
            name  => $fname,
            path  => $rel_target,
            size  => $st[7] // 0,
            mtime => $st[9] // 0,
        };

        log_event( 'INFO', 'file-upload', 'file uploaded',
            path => $rel_target, size => $st[7] // 0,
            user => $auth_user );

        if ( $full_target =~ /\.md$/ ) {
            ( my $cache = $full_target ) =~ s/\.md$/.html/;
            unlink $cache if -f $cache;
        }
    }

    # ok=1 means the request was processed. The client inspects
    # saved/skipped/errors to decide what to show. Returning ok=0
    # when all files were skipped-no-overwrite would make the
    # client show "Upload failed" instead of the overwrite prompt.
    return {
        ok      => 1,
        saved   => \@saved,
        skipped => \@skipped,
        errors  => \@errors,
    };
}

sub detect_content_type {
    my ($path) = @_;
    my ($ext) = $path =~ /\.([^.\/]+)$/;
    return 'application/octet-stream' unless defined $ext;
    return $CONTENT_TYPE_MAP{ lc $ext }
        // 'application/octet-stream';
}

sub is_editable_text {
    my ($path) = @_;
    my ($ext) = $path =~ /\.([^.\/]+)$/;
    return 1 unless defined $ext;   # no extension: assume text
    return $TEXT_EXTENSIONS{ lc $ext } ? 1 : 0;
}

sub action_file_download {
    my ($rel_path) = @_;

    my $result = validate_path($rel_path);
    unless ( $result->{ok} ) {
        respond({ ok => 0, error => $result->{error} });
        return;
    }

    # SM019 decision point: consult is_blocked_path on download so a
    # manager cannot grab lazysite/auth/.secret (or any .pl) through
    # this action just because action_read blocks them. The briefing
    # did not specify this; added for parity with read/save/delete.
    if ( is_blocked_path( $result->{rel} ) ) {
        respond({ ok => 0, error => "Path is blocked" });
        return;
    }
    # SM019c: config block list applies to downloads too, so a
    # caller cannot siphon the manager UI or any other configured
    # sensitive directory via this surface.
    if ( is_blocked_config( $result->{rel} ) ) {
        respond({ ok => 0, error => "Path is blocked by config" });
        return;
    }

    my $full = $result->{full};

    unless ( -f $full ) {
        respond({ ok => 0, error => "File not found" });
        return;
    }
    if ( -d $full ) {
        respond({ ok => 0, error => "Not a file" });
        return;
    }

    my $basename = basename($full);
    my $ctype    = detect_content_type($full);
    my $size     = ( stat $full )[7] // 0;

    ( my $safe_name = $basename ) =~ s/[\r\n"\\]//g;

    log_event( 'DEBUG', 'file-download', 'file downloaded',
        path => $result->{rel}, size => $size,
        user => $auth_user );

    # syswrite below bypasses Perl's stdio buffer; without autoflush
    # the print-ed headers land in stdout AFTER the body bytes.
    binmode STDOUT;
    local $| = 1;
    print "Status: 200 OK\r\n";
    print "Content-Type: $ctype\r\n";
    print "Content-Length: $size\r\n";
    print "Content-Disposition: attachment; filename=\"$safe_name\"\r\n";
    print "Cache-Control: no-store, private\r\n";
    print "\r\n";

    open my $fh, '<', $full or return;
    binmode $fh;
    my $buf;
    while ( my $n = sysread( $fh, $buf, 65536 ) ) {
        syswrite STDOUT, $buf, $n;
    }
    close $fh;
}

# The query-string parser at the top of the script collapses repeated
# keys (last-write-wins). Re-parse from QUERY_STRING directly to pick
# up every paths=... value from the zip-download request.
sub collect_zip_paths {
    my @paths;
    for my $pair ( split /&/, $ENV{QUERY_STRING} // '' ) {
        my ( $k, $v ) = split /=/, $pair, 2;
        next unless defined $k && defined $v;
        next unless $k eq 'paths' || $k eq 'paths[]';
        $v =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
        $v =~ s/\+/ /g;
        push @paths, $v if length $v;
    }
    return @paths;
}

sub action_file_zip_download {
    my @requested = collect_zip_paths();
    unless (@requested) {
        respond({ ok => 0, error => "No files selected" });
        return;
    }

    my $max_total = upload_limits()->{max_bytes} * 10;

    require Archive::Zip;
    Archive::Zip->import(qw(:ERROR_CODES));

    my $zip   = Archive::Zip->new();
    my $total = 0;
    my $added = 0;

    for my $rel (@requested) {
        my $vr = validate_path($rel);
        unless ( $vr->{ok} ) {
            log_event( 'WARN', 'file-zip-download',
                'skipped (invalid path)',
                path => $rel, user => $auth_user );
            next;
        }
        if ( is_blocked_path( $vr->{rel} ) ) {
            log_event( 'WARN', 'file-zip-download',
                'skipped (blocked path)',
                path => $rel, user => $auth_user );
            next;
        }
        # SM019c: config block list applies to zip-download too,
        # mirroring single-file download.
        if ( is_blocked_config( $vr->{rel} ) ) {
            log_event( 'WARN', 'file-zip-download',
                'skipped (blocked by config)',
                path => $rel, user => $auth_user );
            next;
        }

        my $full = $vr->{full};
        unless ( -f $full ) {
            log_event( 'WARN', 'file-zip-download',
                'skipped (not a file)',
                path => $rel, user => $auth_user );
            next;
        }

        my $size = ( stat $full )[7] // 0;
        $total += $size;
        if ( $total > $max_total ) {
            respond({ ok => 0, error => "Total size exceeds limit" });
            return;
        }

        $zip->addFile( $full, $vr->{rel} );
        $added++;
    }

    unless ($added) {
        respond({ ok => 0, error => "No valid files" });
        return;
    }

    require File::Temp;
    my $tmp = File::Temp->new(
        TEMPLATE => 'lazysite-zip-XXXXXX',
        SUFFIX   => '.zip',
        TMPDIR   => 1,
    );
    my $tmp_path = $tmp->filename;

    unless ( $zip->writeToFileNamed($tmp_path) == 0 ) {    # AZ_OK
        respond({ ok => 0, error => "Zip write failed" });
        return;
    }

    my $zip_size = ( stat $tmp_path )[7] // 0;
    my $ts       = strftime( '%Y%m%d-%H%M%S', localtime );
    my $fname    = "lazysite-files-$ts.zip";

    log_event( 'INFO', 'file-zip-download', 'zip downloaded',
        count => $added, size => $zip_size,
        user => $auth_user );

    binmode STDOUT;
    local $| = 1;    # flush headers before the syswrite loop
    print "Status: 200 OK\r\n";
    print "Content-Type: application/zip\r\n";
    print "Content-Length: $zip_size\r\n";
    print "Content-Disposition: attachment; filename=\"$fname\"\r\n";
    print "Cache-Control: no-store, private\r\n";
    print "\r\n";

    open my $fh, '<', $tmp_path or return;
    binmode $fh;
    my $buf;
    while ( my $n = sysread( $fh, $buf, 65536 ) ) {
        syswrite STDOUT, $buf, $n;
    }
    close $fh;
}

# --- Helpers ---

sub _get_lock_info {
    my ($rel_path) = @_;
    my $lock_key = $rel_path;
    $lock_key =~ s{/}{:}g;
    my $lock_file = "$LOCK_DIR/$lock_key.lock";
    return {} unless -f $lock_file;

    open my $lf, '<', $lock_file or return {};
    chomp( my $lc = <$lf> );
    close $lf;
    my ( $by, $at ) = split /\s+/, $lc, 2;
    my $age = time() - ( $at // 0 );
    return { locked_by => $by, locked_at => $at, active => $age < $LOCK_TIMEOUT ? 1 : 0 };
}

# --- Logging ---

sub log_event {
    my ($level, $context, $message, %extra) = @_;
    my $min_level = $ENV{LAZYSITE_LOG_LEVEL} // 'INFO';
    my %rank = ( DEBUG => 0, INFO => 1, WARN => 2, ERROR => 3 );
    return if ( $rank{$level} // 1 ) < ( $rank{$min_level} // 1 );
    use POSIX qw(strftime);
    my $ts = strftime( '%Y-%m-%d %H:%M:%S', localtime );
    my $format = $ENV{LAZYSITE_LOG_FORMAT} // 'text';
    if ( $format eq 'json' ) {
        my $pairs = join ',',
            map  { '"' . _json_str($_) . '":"' . _json_str($extra{$_}) . '"' }
            keys %extra;
        my $json = '{"ts":"' . $ts . '"'
            . ',"level":"'     . _json_str($level)          . '"'
            . ',"component":"' . _json_str($LOG_COMPONENT)  . '"'
            . ',"context":"'   . _json_str($context)        . '"'
            . ',"message":"'   . _json_str($message)        . '"'
            . ( $pairs ? ",$pairs" : '' )
            . '}';
        print STDERR "$json\n";
    }
    else {
        # Defensive undef coercion: helper subs called from unit tests
        # without the normal request context may pass undef $action
        # and undef $auth_user, and we would rather log "[]" than
        # emit "uninitialized value" warnings.
        no warnings 'uninitialized';
        my $extras = join ' ',
            map { "$_=" . ( $extra{$_} // '' ) } keys %extra;
        my $ctx  = $context // '';
        my $line = "[$ts] [$level] [$LOG_COMPONENT] [$ctx] $message";
        $line   .= " $extras" if $extras;
        print STDERR "$line\n";
    }
}

sub _json_str {
    my ($s) = @_;
    $s //= '';
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    return $s;
}
