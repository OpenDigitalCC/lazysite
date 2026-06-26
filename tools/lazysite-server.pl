#!/usr/bin/perl
# lazysite dev server - local development only, not for production use
use strict;
use warnings;
use IO::Socket::INET;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use Encode;

# --- Module check ---

my @required = (
    [ 'IO::Socket::INET',    'libio-socket-inet6-perl' ],
    [ 'Text::MultiMarkdown', 'libtext-multimarkdown-perl' ],
    [ 'Template',            'libtemplate-perl' ],
    [ 'LWP::UserAgent',      'libwww-perl' ],
    [ 'JSON::PP',            'libjson-perl' ],
);

my @missing;
for my $pair ( @required ) {
    my ( $mod, $pkg ) = @$pair;
    # L-11: block-form eval with explicit path munging (no stringy eval)
    eval {
        ( my $file = $mod ) =~ s{::}{/}g;
        require "$file.pm";  ## no critic (Modules::RequireBarewordIncludes)
    };
    push @missing, [ $mod, $pkg ] if $@;
}


if ( @missing ) {
    print "lazysite-server: missing required Perl modules:\n\n";
    printf "  %-30s (package: %s)\n", $_->[0], $_->[1] for @missing;
    print "\nOn Debian/Ubuntu:\n\n";
    print "  sudo apt-get install "
        . join( " \\\n    ", map { $_->[1] } @missing ) . "\n\n";
    print "On other systems, search your package manager for the module name.\n";
    exit 1;
}

# --- Optional modules ---

my @optional = (
    [ 'Template::Plugin::JSON::Escape', 'libtemplate-plugin-json-escape-perl',
      'Required for search index (search-index.md)' ],
);

my @opt_missing;
for my $pair ( @optional ) {
    my ( $mod, $pkg, $note ) = @$pair;
    eval "require $mod";   ## no critic (ProhibitStringyEval) - dynamic optional-module probe, dev server only
    push @opt_missing, [ $mod, $pkg, $note ] if $@;
}

if ( @opt_missing ) {
    print "lazysite-server: optional modules not installed:\n\n";
    printf "  %-40s %s\n", $_->[0], $_->[2] for @opt_missing;
    print "\n  sudo apt-get install "
        . join( " ", map { $_->[1] } @opt_missing ) . "\n\n";
}

my $has_hires = eval { require Time::HiRes; 1 };

my $LOG_COMPONENT = 'dev-server';

# SM051: ignore SIGPIPE so the server survives mid-response client
# disconnects (browser tab closed, navigation away, DevTools abort).
# Without this the write syscall gets SIGPIPE on the broken pipe and
# the server process exits 141. Ignoring the signal makes the write
# return EPIPE which the regular IO error path handles.
$SIG{PIPE} = 'IGNORE';

# SM091: exit cleanly on Ctrl-C / kill so the END block runs (removing the
# temporary browse cache and the error file). A signal otherwise terminates the
# process without running END, leaving /tmp/lazysite-browse-<pid> behind.
$SIG{INT} = $SIG{TERM} = sub { exit 0 };

# --- Defaults ---

my $SCRIPT_DIR = dirname( abs_path($0) );
my $PORT       = 8080;
my $DOCROOT    = abs_path("$SCRIPT_DIR/../starter");
my $PROCESSOR  = abs_path("$SCRIPT_DIR/../lazysite-processor.pl");
my $nocache    = 1;
my $auto_index = 0;    # SM091: generate index + breadcrumb nav for an arbitrary tree
my $seed       = 1;    # seed scaffolding into a lazysite docroot (off for browsing)
my $ERR_FILE   = "/tmp/lazysite-server-$$.err";
my $LOG_FILE   = '';
my $BROWSE_CACHE = '';    # SM091: off-docroot cache base, set in --auto-index mode

END {
    unlink $ERR_FILE if -f $ERR_FILE;
    if ( $BROWSE_CACHE && -d $BROWSE_CACHE ) {
        require File::Path;
        File::Path::remove_tree($BROWSE_CACHE);
    }
}

# --- Parse arguments ---

my $show_help = 0;

while ( @ARGV ) {
    my $arg = shift @ARGV;
    if    ( $arg eq '--port' )      { $PORT      = shift @ARGV; }
    elsif ( $arg eq '--docroot' )   { $DOCROOT   = abs_path( shift @ARGV ); }
    elsif ( $arg eq '--processor' ) { $PROCESSOR = abs_path( shift @ARGV ); }
    elsif ( $arg eq '--cache' )      { $nocache    = 0; }
    elsif ( $arg eq '--auto-index' ) { $auto_index = 1; }
    elsif ( $arg eq '--no-seed' )    { $seed       = 0; }
    elsif ( $arg eq '--debug' )     { $ENV{LAZYSITE_LOG_LEVEL} = 'DEBUG'; }
    elsif ( $arg eq '--log' )       { $LOG_FILE  = shift @ARGV; }
    elsif ( $arg eq '--help' )      { $show_help = 1; }
    else {
        print STDERR "lazysite-server: unknown option: $arg\n";
        exit 1;
    }
}

if ( $show_help ) {
    print <<'HELP';
lazysite dev server - local development only, not for production use

Usage: perl tools/lazysite-server.pl [options]

Options:
  --port      PORT    Port to listen on (default: 8080)
  --docroot   PATH    Document root (default: ../starter)
  --processor PATH    Processor path (default: ../lazysite-processor.pl)
  --cache             Respect cache files (default: always regenerate)
  --auto-index        Generate a directory index + breadcrumb nav for any tree
                      that has no index.md (writes nothing to the docroot)
  --no-seed           Never seed lazysite scaffolding into the docroot
  --debug             Enable DEBUG level logging
  --log       FILE    Write log lines to file in addition to terminal
  --help              Show this help

No arguments needed to browse the starter site:

  cd /path/to/lazysite
  perl tools/lazysite-server.pl
  open http://localhost:8080/

To serve your own site:

  perl tools/lazysite-server.pl --docroot /path/to/your/public_html

To browse any tree of Markdown (no install, no cache, no theme, no index
files, nothing written back) - e.g. a docs/ folder or notes corpus:

  perl tools/lazysite-server.pl --docroot /path/to/tree --auto-index

Scaffolding is only ever seeded into a real lazysite docroot (one with a
lazysite/ dir or lazysite.conf.example); an arbitrary tree is left untouched.
--auto-index implies a read-only browse and never seeds.
HELP
    exit 0;
}

# --- Validate paths ---

unless ( -d $DOCROOT ) {
    print STDERR "lazysite-server: docroot not found: $DOCROOT\n";
    exit 1;
}

unless ( -f $PROCESSOR ) {
    print STDERR "lazysite-server: processor not found: $PROCESSOR\n";
    exit 1;
}

# --- MIME types ---

my %MIME = (
    css   => 'text/css',
    js    => 'application/javascript',
    png   => 'image/png',
    jpg   => 'image/jpeg',
    jpeg  => 'image/jpeg',
    gif   => 'image/gif',
    svg   => 'image/svg+xml',
    ico   => 'image/x-icon',
    woff  => 'font/woff',
    woff2 => 'font/woff2',
    txt   => 'text/plain',
    xml   => 'application/xml',
    json  => 'application/json',
    pdf   => 'application/pdf',
);

# --- Seed scaffolding (only into a real lazysite docroot) ---

# SM091: seed auth/forms/conf scaffolding ONLY when the docroot is actually a
# lazysite site (it has a lazysite/ dir or a lazysite.conf.example). Pointed at an
# arbitrary tree - or in --auto-index browse mode, or with --no-seed - the server
# writes nothing into the docroot.
my $is_lazysite_docroot = ( -d "$DOCROOT/lazysite" )
    || ( -f "$DOCROOT/lazysite.conf.example" );
my $do_seed = $seed && !$auto_index && $is_lazysite_docroot;

# In browse mode, keep the processor's compile/layout cache off the docroot so
# rendering a page writes nothing into the tree being browsed.
$BROWSE_CACHE = "/tmp/lazysite-browse-$$" if $auto_index;

# --- Seed auth files from examples if needed ---

my $auth_dir = "$DOCROOT/lazysite/auth";
if ($do_seed) {
    require File::Path;
    File::Path::make_path($auth_dir) unless -d $auth_dir;
    for my $base (qw(users groups)) {
        my $example = "$auth_dir/$base.example";
        my $target  = "$auth_dir/$base";
        if ( -f $example && ! -f $target ) {
            require File::Copy;
            File::Copy::copy( $example, $target );
            print "  seeded: lazysite/auth/$base\n";
        }
    }
}

# --- Seed lazysite.conf if missing ---

my $conf_target = "$DOCROOT/lazysite/lazysite.conf";
my $conf_source = "$DOCROOT/lazysite.conf.example";
if ( $do_seed && ! -f $conf_target && -f $conf_source ) {
    require File::Copy;
    require File::Path;
    File::Path::make_path( "$DOCROOT/lazysite" );
    File::Copy::copy( $conf_source, $conf_target );
    print "  seeded: lazysite/lazysite.conf\n";
}

# Copy manager CSS to web-accessible path
{
    my $src = "$DOCROOT/lazysite/manager/assets/manager.css";
    my $dst = "$DOCROOT/manager/assets/manager.css";
    if ( $do_seed && -f $src ) {
        require File::Path;
        require File::Copy;
        File::Path::make_path("$DOCROOT/manager/assets") unless -d "$DOCROOT/manager/assets";
        File::Copy::copy( $src, $dst );
    }
}

# Seed form config from .example files if missing
if ($do_seed) {
    my $forms_dir = "$DOCROOT/lazysite/forms";
    require File::Path;
    File::Path::make_path($forms_dir) unless -d $forms_dir;
    require File::Copy;
    for my $base (qw(contact handlers smtp)) {
        my $target  = "$forms_dir/$base.conf";
        my $example = "$forms_dir/$base.conf.example";
        if ( ! -f $target && -f $example ) {
            File::Copy::copy( $example, $target );
            print "  seeded: lazysite/forms/$base.conf\n";
        }
    }
}

my $nav_target = "$DOCROOT/lazysite/nav.conf";
my $nav_source = "$DOCROOT/nav.conf.example";
if ( $do_seed && ! -f $nav_target && -f $nav_source ) {
    require File::Copy;
    File::Copy::copy( $nav_source, $nav_target );
    print "  seeded: lazysite/nav.conf\n";
}

# --- Seed log config from lazysite.conf (env var takes priority) ---

{
    my $conf_path = "$DOCROOT/lazysite/lazysite.conf";
    if ( -f $conf_path && open my $fh, '<', $conf_path ) {
        while (<$fh>) {
            if ( /^\s*log_level\s*:\s*(\S+)/ && !$ENV{LAZYSITE_LOG_LEVEL} ) {
                $ENV{LAZYSITE_LOG_LEVEL} = $1;
            }
            if ( /^\s*log_format\s*:\s*(\S+)/ && !$ENV{LAZYSITE_LOG_FORMAT} ) {
                $ENV{LAZYSITE_LOG_FORMAT} = $1;
            }
        }
        close $fh;
    }
}

# --- Start server ---

my $cache_label = $nocache ? 'disabled (pass --cache to enable)' : 'enabled';

my $manager_enabled = 0;
if ( open my $cfh, '<', "$DOCROOT/lazysite/lazysite.conf" ) {
    while (<$cfh>) { $manager_enabled = 1 if /^(?:manager|editor)\s*:\s*enabled/i }
    close $cfh;
}

print "lazysite dev server\n";
print "  processor: $PROCESSOR\n";
print "  docroot:   $DOCROOT\n";
print "  url:       http://localhost:$PORT/\n";
print "  cache:     $cache_label\n";
print "  auto-index: " . ($auto_index ? "on (generated index + breadcrumb nav)" : "off") . "\n";
print "  seeding:   " . ($do_seed ? "on" : "off (docroot left untouched)") . "\n";
print "  manager:   " . ($manager_enabled ? "enabled" : "disabled") . "\n";
print "  log level: " . ($ENV{LAZYSITE_LOG_LEVEL} // 'INFO') . "\n";
print "  log format: " . ($ENV{LAZYSITE_LOG_FORMAT} // 'text') . "\n";
print "  log file:  " . ($LOG_FILE || 'terminal only') . "\n" if $LOG_FILE;
print "\nPress Ctrl+C to stop.\n\n";

my $server = IO::Socket::INET->new(
    LocalAddr => '0.0.0.0',
    LocalPort => $PORT,
    Proto     => 'tcp',
    Listen    => 5,
    ReuseAddr => 1,
) or die "lazysite-server: cannot bind to port $PORT: $!\n";

# --- Main loop ---

while ( my $client = $server->accept() ) {
    handle_request($client);
    close $client;
}

# --- Request handler ---

sub handle_request {
    my ($client) = @_;

    # SM019c: byte semantics for all socket I/O. Without this, any
    # inherited or default PerlIO layer could decode/encode bytes
    # on write, which double-encodes binary CGI bodies (zip, image).
    binmode $client;

    my $t0 = $has_hires ? Time::HiRes::time() : 0;

    # Read request line
    my $request_line = <$client>;
    return unless defined $request_line;
    $request_line =~ s/\r?\n$//;

    # Read headers
    my %req_headers;
    my $content_length = 0;
    my $content_type_req = '';
    while ( my $header = <$client> ) {
        last if $header =~ /^\r?\n$/;
        if ( $header =~ /^([^:]+):\s*(.+?)\r?\n?$/ ) {
            $req_headers{ lc($1) } = $2;
        }
    }
    $content_length  = $req_headers{'content-length'} || 0;
    $content_type_req = $req_headers{'content-type'}   || '';

    # Read POST body
    my $post_body = '';
    if ( $content_length > 0 ) {
        read( $client, $post_body, $content_length );
    }

    # Parse method and URI
    my ( $method, $raw_uri ) = $request_line =~ m{^(\S+)\s+(\S+)};
    return unless defined $method && defined $raw_uri;

    # Strip query string for file lookup, capture for CGI env
    my $query_string = '';
    ( my $uri = $raw_uri ) =~ s/\?(.*)$// && ( $query_string = $1 );

    # Normalise: / -> /index for processor, but check static first
    my $file_path = $DOCROOT . $uri;

    # Static file serving
    # Skip .html files that have a .md or .url source - let the processor handle them
    if ( $method eq 'GET' && -f $file_path && $file_path !~ /\.(md|url|tt|conf|brief)$/
         && !( $file_path =~ /\.html$/ && ( -f ($file_path =~ s/\.html$/.md/r) || -f ($file_path =~ s/\.html$/.url/r) ) ) ) {
        serve_static( $client, $file_path, $method, $uri, $t0 );
        return;
    }

    # SM091: --auto-index. A GET for a directory with no index.md (and no
    # same-named <dir>.md) gets a generated listing instead of a 404, so an
    # arbitrary tree of Markdown is browsable. Nothing is written to the docroot.
    if ( $auto_index && $method eq 'GET' ) {
        ( my $dpath = $uri ) =~ s{/+$}{};
        my $dir_fs = length $dpath ? "$DOCROOT$dpath" : $DOCROOT;
        if ( -d $dir_fs && ! -f "$dir_fs/index.md" && ! -f "$dir_fs.md" ) {
            serve_auto_index( $client, $dir_fs, $uri, $t0 );
            return;
        }
    }

    # Determine which script to run
    my $auth_script  = abs_path("$SCRIPT_DIR/../lazysite-auth.pl");
    my $manager_api  = abs_path("$SCRIPT_DIR/../lazysite-manager-api.pl");
    my $auth_users   = "$DOCROOT/lazysite/auth/users";
    my $use_auth     = -f $auth_users && -f $auth_script;

    # Pick the ultimate target CGI. Default is the processor; /cgi-bin/*.pl
    # overrides with the explicit script.
    my $target = $PROCESSOR;
    my $target_rel;
    if ( $uri =~ m{^/cgi-bin/(lazysite-[\w-]+\.pl)} ) {
        $target_rel = $1;
        my $cgi_script = abs_path("$SCRIPT_DIR/../$target_rel");
        $target = $cgi_script if $cgi_script && -f $cgi_script;
    }

    # SM070: /dav routes straight to lazysite-dav.pl, bypassing the auth
    # wrapper - the WebDAV endpoint performs its own HTTP Basic auth and
    # must not see cookie-derived X-Remote-* headers. PATH_INFO is the
    # part after /dav, url-decoded to match what Apache's ScriptAlias
    # would hand a CGI; SCRIPT_NAME is the mount point.
    my $is_dav        = 0;
    my $dav_path_info = '';
    if ( $uri eq '/dav' || $uri =~ m{^/dav/} ) {
        my $dav_script = abs_path("$SCRIPT_DIR/../lazysite-dav.pl");
        if ( $dav_script && -f $dav_script ) {
            $is_dav        = 1;
            $target        = $dav_script;
            $dav_path_info = $uri;
            $dav_path_info =~ s{^/dav}{};
            $dav_path_info =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
        }
    }

    # Under `use_auth` mode, always run lazysite-auth.pl first so that
    # HTTP_X_REMOTE_USER / _GROUPS are set from the signed cookie before
    # the target CGI (processor OR manager-api OR any other cgi-bin
    # script) runs. The auth wrapper exec()s whatever LAZYSITE_PROCESSOR
    # points at, so we thread the real target through that env var.
    #
    # Exception: requests *to* lazysite-auth.pl itself (login/logout
    # endpoints) must go direct, or we'd exec ourselves recursively.
    my $script = $target;
    if ( $use_auth && !$is_dav ) {
        my $target_is_auth = defined $target_rel && $target_rel eq 'lazysite-auth.pl';
        $script = $auth_script unless $target_is_auth;
    }

    # Build CGI environment
    my %env = (
        DOCUMENT_ROOT    => $DOCROOT,
        REDIRECT_URL     => $uri,
        REQUEST_URI      => $raw_uri,
        REQUEST_METHOD   => $method,
        QUERY_STRING     => $query_string,
        CONTENT_LENGTH   => $content_length,
        CONTENT_TYPE     => $content_type_req,
        REQUEST_SCHEME   => 'http',
        SERVER_NAME      => 'localhost',
        SERVER_PORT      => $PORT,
        REMOTE_ADDR      => $client->peerhost || '127.0.0.1',
        LAZYSITE_NOCACHE    => $nocache,
        LAZYSITE_PROCESSOR  => $target,  # real CGI target (auth wrapper execs this)
        ( $BROWSE_CACHE ? ( LAZYSITE_CACHE_DIR => "$BROWSE_CACHE/cache" ) : () ),
        ( $ENV{LAZYSITE_LOG_LEVEL}  ? ( LAZYSITE_LOG_LEVEL  => $ENV{LAZYSITE_LOG_LEVEL}  ) : () ),
        ( $ENV{LAZYSITE_LOG_FORMAT} ? ( LAZYSITE_LOG_FORMAT => $ENV{LAZYSITE_LOG_FORMAT} ) : () ),
    );

    # Forward every request header to the CGI env per the CGI/1.1
    # convention: `X-Foo-Bar: baz` becomes HTTP_X_FOO_BAR=baz. The two
    # exceptions are Content-Length and Content-Type, which go in as
    # CONTENT_LENGTH / CONTENT_TYPE without the HTTP_ prefix - those
    # are already set above from the parsed values. Previously only
    # Cookie was forwarded, which silently dropped X-CSRF-Token (and
    # anything else the client sent), breaking the manager API's CSRF
    # verification on POST.
    for my $h ( keys %req_headers ) {
        next if $h eq 'content-length' || $h eq 'content-type';
        ( my $env_key = uc($h) ) =~ tr/-/_/;
        $env{"HTTP_$env_key"} = $req_headers{$h};
    }

    if ($is_dav) {
        $env{PATH_INFO}   = $dav_path_info;
        $env{SCRIPT_NAME} = '/dav';
    }

    local @ENV{ keys %env } = values %env;

    my $output;
    if ( length $post_body ) {
        my $post_file = "/tmp/lazysite-post-$$.dat";
        # L-7: previously this open() was unchecked - silent data loss if
        # /tmp was full. Now 500s back to the client on failure.
        my $pf;
        unless ( open( $pf, '>:raw', $post_file ) ) {
            my $err = $!;
            log_event('ERROR', $uri, 'cannot write POST tempfile',
                path => $post_file, error => $err);
            print $client "HTTP/1.0 500 Internal Server Error\r\n";
            print $client "Content-Type: text/plain\r\n\r\n";
            print $client "500 Internal Server Error\n";
            return;
        }
        print $pf $post_body;
        close $pf;
        $output = qx(cat \Q$post_file\E | perl \Q$script\E 2>$ERR_FILE);
        unlink $post_file;
    }
    else {
        $output = qx(perl \Q$script\E 2>$ERR_FILE);
    }

    # Display stderr log lines with colour
    if ( -s $ERR_FILE ) {
        open my $err, '<', $ERR_FILE;
        while ( my $line = <$err> ) {
            chomp $line;
            display_log_line($line);
            if ( $LOG_FILE && open my $lf, '>>', $LOG_FILE ) {
                print $lf "$line\n";
                close $lf;
            }
        }
        close $err;
    }

    # Parse CGI response - split headers from body at blank line
    my $status       = '200 OK';
    my $content_type = 'text/html; charset=utf-8';
    my %extra_headers;

    if ( $output =~ s/\A(.*?)\r?\n\r?\n//s ) {
        my $header_block = $1;
        for my $line ( split /\r?\n/, $header_block ) {
            if ( $line =~ /^Status:\s*(.+)/i ) {
                $status = $1;
            }
            elsif ( $line =~ /^Content-type:\s*(.+)/i ) {
                $content_type = $1;
            }
            elsif ( $line =~ /^([^:]+):\s*(.+)/ ) {
                $extra_headers{$1} = $2;
            }
        }
    }

    # Send HTTP response.
    #
    # SM019c: qx() already returns raw bytes from the CGI process
    # (no utf8 flag set), so passing them through Encode::encode_utf8
    # double-encodes every high byte and corrupts binary responses
    # (zip download, image/* downloads). For text responses the
    # CGI already emits UTF-8 bytes via its own ':utf8' layer, so
    # passing the raw bytes through is correct in both cases.
    # Force-clear any utf8 flag defensively via the ::bytes scope
    # so length() gives byte count even if some future change taints
    # $output with the flag.
    my $body = $output;

    # SM091: --auto-index also injects a breadcrumb nav at the top of each
    # rendered page, so any note links back up to its folder and the root
    # without a nav.conf and without writing anything.
    if ( $auto_index && $content_type =~ /html/i && $body =~ /<body[^>]*>/i ) {
        my $crumb = breadcrumb_html($uri);
        $body =~ s{(<body[^>]*>)}{$1\n$crumb}i;
    }

    my $length = do { use bytes; length($body) };

    # Content-Type from the CGI may declare its own charset (most
    # do for text, none for binary). Forward it verbatim.

    print $client "HTTP/1.0 $status\r\n";
    print $client "Content-Type: $content_type\r\n";
    for my $h ( sort keys %extra_headers ) {
        print $client "$h: $extra_headers{$h}\r\n";
    }
    print $client "Content-Length: $length\r\n";
    print $client "Connection: close\r\n";
    print $client "\r\n";
    print $client $body;

    # Log
    my $ms = $has_hires ? int( ( Time::HiRes::time() - $t0 ) * 1000 ) : 0;
    log_event('INFO', $uri, 'request', method => $method, status => $status, ms => $ms);
}

sub serve_static {
    my ( $client, $file_path, $method, $uri, $t0 ) = @_;

    # Determine MIME type
    my $ext = '';
    $ext = lc($1) if $file_path =~ /\.(\w+)$/;
    my $content_type = $MIME{$ext} || 'application/octet-stream';

    # Read file
    open my $fh, '<:raw', $file_path or do {
        print $client "HTTP/1.0 500 Internal Server Error\r\n";
        print $client "Content-Type: text/plain\r\n";
        print $client "Connection: close\r\n";
        print $client "\r\n";
        print $client "Cannot read file\n";

        my $ms = $has_hires ? int( ( Time::HiRes::time() - $t0 ) * 1000 ) : 0;
        log_event('ERROR', $uri, 'request', method => $method, status => '500 Internal Server Error', ms => $ms, error => $!);
        return;
    };
    local $/;
    my $body = <$fh>;
    close $fh;

    my $length = length($body);

    print $client "HTTP/1.0 200 OK\r\n";
    print $client "Content-Type: $content_type\r\n";
    if ( $ext eq 'html' || $ext eq 'htm' ) {
        print $client "Cache-Control: no-cache, must-revalidate\r\n";
        print $client "Vary: Cookie\r\n";
    }
    print $client "Content-Length: $length\r\n";
    print $client "Connection: close\r\n";
    print $client "\r\n";
    print $client $body;

    my $ms = $has_hires ? int( ( Time::HiRes::time() - $t0 ) * 1000 ) : 0;
    log_event('INFO', $uri, 'request', method => $method, status => '200 OK', ms => $ms, static => 1);
}

# --- SM091: auto-index (generated directory listing + breadcrumb nav) ---

sub _auto_esc {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    return $s;
}

# Friendly label for a note: its front-matter title, else the slug.
sub _auto_title {
    my ($file) = @_;
    open my $fh, '<', $file or return undef;
    my ( $n, $title ) = ( 0, undef );
    while ( my $l = <$fh> ) {
        last if $n++ > 10 || ( $n > 1 && $l =~ /^---\s*$/ );
        if ( $l =~ /^title:\s*"?(.*?)"?\s*$/ ) { $title = $1; last }
    }
    close $fh;
    return ( defined $title && length $title ) ? $title : undef;
}

# index / area / page trail, links to each ancestor directory's index.
sub breadcrumb_html {
    my ($uri) = @_;
    ( my $p = $uri ) =~ s{/+$}{};
    $p =~ s{^/+}{};
    my @parts = length $p ? split m{/}, $p : ();
    my $crumb = '<nav class="ls-crumb"><a href="/">&#127968; index</a>';
    my $acc   = '';
    for my $i ( 0 .. $#parts ) {
        $acc .= '/' . $parts[$i];
        ( my $label = $parts[$i] ) =~ s/\.md$//;
        if ( $i == $#parts ) {
            $crumb .= ' &rsaquo; <span class="here">' . _auto_esc($label) . '</span>';
        }
        else {
            $crumb .= ' &rsaquo; <a href="' . _auto_esc($acc) . '/">'
                . _auto_esc($label) . '</a>';
        }
    }
    return $crumb . '</nav>';
}

# HTML for a directory index. Reads the filesystem only; returns undef if the
# directory cannot be opened. Pure enough to unit-test.
sub render_auto_index {
    my ( $dir_fs, $uri ) = @_;
    opendir my $dh, $dir_fs or return undef;
    my ( @dirs, @notes, $has_readme );
    for my $e ( sort readdir $dh ) {
        next if $e =~ /^\./;
        next if $e eq 'lazysite' || $e eq 'manager';
        if    ( -d "$dir_fs/$e" )                    { push @dirs, $e }
        elsif ( $e =~ /\.md$/ && $e ne 'index.md' )  {
            if ( $e eq 'README.md' ) { $has_readme = 1 }
            else                     { push @notes, $e }
        }
    }
    closedir $dh;

    ( my $base = $uri ) =~ s{/+$}{};          # '' at root, '/auth' otherwise
    my $name = ( $base =~ m{([^/]+)$} ) ? $1 : 'index';

    my $h = breadcrumb_html($uri);
    $h .= '<h1>' . _auto_esc($name) . "</h1>\n";
    $h .= qq{<p class="ls-note">Generated index - no <code>index.md</code> here }
        . qq{(lazysite dev server, <code>--auto-index</code>).</p>\n};
    if ($has_readme) {
        $h .= qq{<p class="ls-overview"><a href="$base/README">}
            . qq{&#128196; Overview (README)</a></p>\n};
    }
    if (@dirs) {
        $h .= "<h2>Folders</h2>\n<ul class=\"ls-list\">\n";
        $h .= qq{  <li><a href="$base/$_/">&#128193; } . _auto_esc($_) . "/</a></li>\n"
            for @dirs;
        $h .= "</ul>\n";
    }
    if (@notes) {
        $h .= "<h2>Pages</h2>\n<ul class=\"ls-list\">\n";
        for my $note (@notes) {
            ( my $slug = $note ) =~ s/\.md$//;
            my $label = _auto_title("$dir_fs/$note") // $slug;
            $h .= qq{  <li><a href="$base/$slug">} . _auto_esc($label) . '</a> '
                . '<span class="ls-fn">' . _auto_esc($note) . "</span></li>\n";
        }
        $h .= "</ul>\n";
    }
    $h .= "<p><em>empty directory</em></p>\n" unless @dirs || @notes || $has_readme;

    return _auto_page( $name, $h );
}

sub _auto_page {
    my ( $title, $inner ) = @_;
    my $t = _auto_esc($title);
    return <<"HTML";
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>$t - index</title>
<style>
  body { font-family: system-ui, sans-serif; max-width: 800px; margin: 2rem auto;
         padding: 0 1rem; color: #333; line-height: 1.5; }
  h1 { margin: 0.2rem 0 0.6rem; } h2 { margin-top: 1.4rem; color: #555; }
  a { color: #0066cc; text-decoration: none; } a:hover { text-decoration: underline; }
  .ls-crumb { font-size: 0.85rem; padding: 0.4rem 0; border-bottom: 1px solid #eee;
              margin-bottom: 1rem; color: #888; }
  .ls-crumb .here { color: #333; font-weight: 600; }
  .ls-note { color: #888; font-size: 0.85rem; }
  .ls-overview { font-size: 1.05rem; }
  .ls-list { list-style: none; padding-left: 0; }
  .ls-list li { padding: 0.2rem 0; }
  .ls-fn { color: #aaa; font-size: 0.8rem; font-family: monospace; margin-left: 0.4rem; }
  code { background: #f4f4f4; padding: 0.1rem 0.3rem; border-radius: 3px; }
</style>
</head>
<body>
$inner</body>
</html>
HTML
}

sub serve_auto_index {
    my ( $client, $dir_fs, $uri, $t0 ) = @_;
    my $html = render_auto_index( $dir_fs, $uri );
    unless ( defined $html ) {
        print $client "HTTP/1.0 500 Internal Server Error\r\n";
        print $client "Content-Type: text/plain\r\nConnection: close\r\n\r\n";
        print $client "cannot read directory\n";
        return;
    }
    my $length = do { use bytes; length($html) };
    print $client "HTTP/1.0 200 OK\r\n";
    print $client "Content-Type: text/html; charset=utf-8\r\n";
    print $client "Cache-Control: no-cache, must-revalidate\r\n";
    print $client "Content-Length: $length\r\n";
    print $client "Connection: close\r\n\r\n";
    print $client $html;
    my $ms = $has_hires ? int( ( Time::HiRes::time() - $t0 ) * 1000 ) : 0;
    log_event( 'INFO', $uri, 'auto-index', status => '200 OK', ms => $ms );
}

# --- Logging ---

my %LEVEL_COLOUR = (
    DEBUG => "\033[0;37m",
    INFO  => "\033[0;32m",
    WARN  => "\033[0;33m",
    ERROR => "\033[0;31m",
);
my $RESET = "\033[0m";

sub display_log_line {
    my ($line) = @_;
    return unless length $line;
    my $colour = '';
    if    ( $line =~ /\[DEBUG\]/ ) { $colour = $LEVEL_COLOUR{DEBUG} }
    elsif ( $line =~ /\[INFO\]/  ) { $colour = $LEVEL_COLOUR{INFO}  }
    elsif ( $line =~ /\[WARN\]/  ) { $colour = $LEVEL_COLOUR{WARN}  }
    elsif ( $line =~ /\[ERROR\]/ ) { $colour = $LEVEL_COLOUR{ERROR} }
    if ( -t STDOUT && $colour ) {
        print "$colour$line$RESET\n";
    } else {
        print "$line\n";
    }
}

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
        my $extras = join ' ',
            map { "$_=" . $extra{$_} } keys %extra;
        my $line = "[$ts] [$level] [$LOG_COMPONENT] [$context] $message";
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
