#!/usr/bin/perl
# lazysite-editor-api.pl - file operations CGI for lazysite editor
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use File::Find;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Cwd qw(realpath);
use IPC::Open2;

my $DOCROOT      = $ENV{DOCUMENT_ROOT} // die "No DOCUMENT_ROOT\n";
my $LAZYSITE_DIR = "$DOCROOT/lazysite";
my $LOCK_DIR     = "$LAZYSITE_DIR/editor/locks";
my $LOCK_TIMEOUT = 300;

my @BLOCKED_PATHS = (
    'lazysite/auth/.secret',
    'lazysite/forms/.secret',
    'lazysite/auth/users',
    'lazysite/auth/groups',
);

# --- Auth check ---

my $auth_user = $ENV{HTTP_X_REMOTE_USER} // '';
unless ( $auth_user ) {
    respond({ ok => 0, error => "Authentication required" });
    exit 0;
}

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
    read( STDIN, $body, $len ) if $len > 0;
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
elsif ( $action eq 'users' )            { $result = action_users($body) }
else  { $result = { ok => 0, error => "Unknown action: $action" } }

respond($result);

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
        return 1 if $rel_path eq $blocked;
    }
    return 1 if $rel_path =~ /\.pl$/;
    return 0;
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
        push @entries, {
            name  => $name,
            path  => $rel,
            type  => -d $full ? 'dir' : 'file',
            size  => -d $full ? 0 : ( $st[7] // 0 ),
            mtime => $st[9] // 0,
        };
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

    open my $fh, '>:utf8', $full or return { ok => 0, error => "Cannot write file: $!" };
    print $fh $content;
    close $fh;

    # Invalidate cache
    ( my $cache = $full ) =~ s/\.md$/.html/;
    unlink $cache if -f $cache;

    # Release lock
    unlink $lock_file if -f $lock_file;

    return { ok => 1, path => $rel_path, mtime => ( stat $full )[9] };
}

sub action_delete {
    my ( $rel_path, $username ) = @_;

    my $result = validate_path($rel_path);
    return $result unless $result->{ok};

    return { ok => 0, error => "Path is blocked" }
        if is_blocked_path( $result->{rel} );

    my $full = $result->{full};
    return { ok => 0, error => "Cannot delete directories" } if -d $full;
    return { ok => 0, error => "File not found" } unless -f $full;

    unlink $full or return { ok => 0, error => "Cannot delete: $!" };

    ( my $cache = $full ) =~ s/\.md$/.html/;
    unlink $cache if -f $cache;

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
            return if $File::Find::dir =~ /lazysite/;
            my $rel = $File::Find::name;
            $rel =~ s{^\Q$DOCROOT\E}{};
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
                return if $File::Find::dir =~ /lazysite/;
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

    if ( $conf =~ /^theme\s*:/m ) {
        $conf =~ s/^theme\s*:.*$/theme: $theme_name/m;
    }
    else {
        $conf .= "\ntheme: $theme_name\n";
    }

    open my $out, '>:utf8', $conf_path or return { ok => 0, error => "Cannot write conf" };
    print $out $conf;
    close $out;

    # Invalidate all cached pages
    find( sub { unlink $_ if /\.html$/ && $File::Find::dir !~ /lazysite/ }, $DOCROOT );

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

    system( "rm", "-rf", $theme_dir );
    my $assets_dir = "$DOCROOT/lazysite-assets/$theme_name";
    system( "rm", "-rf", $assets_dir ) if -d $assets_dir;

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

    my $tmp_dir = "/tmp/lazysite-theme-$$";
    make_path($tmp_dir);

    my $zip_path = "$tmp_dir/upload.zip";
    open my $fh, '>:raw', $zip_path or return { ok => 0, error => "Cannot write upload" };
    print $fh $zip_data;
    close $fh;

    my $extract_dir = "$tmp_dir/extracted";
    make_path($extract_dir);
    system( "unzip", "-q", "-o", $zip_path, "-d", $extract_dir );

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

    # Path traversal check
    my $entries = `unzip -l \Q$zip_path\E 2>/dev/null`;
    if ( $entries =~ m{\.\./} ) {
        _cleanup_tmp($tmp_dir);
        return { ok => 0, error => "Invalid zip - path traversal detected" };
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
    system( "cp", "-r", "$extract_dir/.", $dest );

    if ( -d "$extract_dir/assets" ) {
        my $assets_dest = "$DOCROOT/lazysite-assets/$install_name";
        make_path($assets_dest);
        system( "cp", "-r", "$extract_dir/assets/.", $assets_dest );
    }

    _cleanup_tmp($tmp_dir);

    return { ok => 1, name => $install_name, installed_as => $install_name };
}

sub _cleanup_tmp {
    my ($dir) = @_;
    system( "rm", "-rf", $dir ) if $dir =~ m{^/tmp/lazysite-theme-\d+$};
}

# --- User management proxy ---

sub action_users {
    my ($request_body) = @_;

    my $users_script = dirname($0) . "/../tools/lazysite-users.pl";
    unless ( -f $users_script ) {
        $users_script = "$DOCROOT/../tools/lazysite-users.pl";
    }
    return { ok => 0, error => "User management not available" }
        unless -f $users_script;

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
