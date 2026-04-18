#!/usr/bin/perl
# lazysite-editor-api.pl - file operations CGI for lazysite editor
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use File::Find;
use File::Path qw(make_path);
use File::Basename qw(dirname basename);
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

# Read editor_groups from lazysite.conf to determine if auth is required
my $editor_groups_conf = '';
if ( open my $cfh, '<', "$LAZYSITE_DIR/lazysite.conf" ) {
    while (<$cfh>) {
        $editor_groups_conf = $1 if /^editor_groups\s*:\s*(.+)/;
    }
    close $cfh;
}
$editor_groups_conf =~ s/^\s+|\s+$//g;

my $auth_user = $ENV{HTTP_X_REMOTE_USER} // '';
if ( $editor_groups_conf && !$auth_user ) {
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
elsif ( $action eq 'plugin-list' )      { $result = action_plugin_list() }
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

    my @st = stat($full);
    return { ok => 1, path => $rel_path, mtime => $st[9] // 0 };
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

# --- Plugin actions ---

sub resolve_plugin_script {
    my ($script) = @_;
    return undef unless $script;
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
    return undef;
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
    open my $fh, '>:utf8', $path or return { ok => 0, error => "Cannot write nav: $!" };
    print $fh $content;
    close $fh;

    return { ok => 1 };
}

sub action_plugin_list {
    my $conf_path = "$DOCROOT/lazysite/lazysite.conf";
    my @plugin_scripts;

    if ( open my $fh, '<:utf8', $conf_path ) {
        my $in_plugins = 0;
        while (<$fh>) {
            chomp;
            if ( /^plugins\s*:\s*$/ ) { $in_plugins = 1; next }
            if ( $in_plugins && /^\s+-\s+(.+)$/ ) {
                my $s = $1;
                $s =~ s/^\s+|\s+$//g;
                push @plugin_scripts, $s;
            }
            elsif ( $in_plugins && !/^\s/ ) { $in_plugins = 0 }
        }
        close $fh;
    }

    my @plugins;
    for my $script (@plugin_scripts) {
        my $full = resolve_plugin_script($script);
        next unless $full;

        my $json = qx($^X \Q$full\E --describe 2>/dev/null);
        next unless $json;

        my $desc = eval { decode_json($json) };
        next unless $desc && ref $desc eq 'HASH';

        $desc->{_script} = $script;
        push @plugins, $desc;
    }

    return { ok => 1, plugins => \@plugins };
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
        open my $fh, '>:utf8', $conf_path
            or return { ok => 0, error => "Cannot write config: $!" };
        print $fh $content;
        close $fh;
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

        open my $fh, '>:utf8', $conf_path
            or return { ok => 0, error => "Cannot write lazysite.conf: $!" };
        print $fh $content;
        close $fh;
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
