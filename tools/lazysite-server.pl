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
    eval "require $mod";
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

# --- Defaults ---

my $SCRIPT_DIR = dirname( abs_path($0) );
my $PORT       = 8080;
my $DOCROOT    = abs_path("$SCRIPT_DIR/../starter");
my $PROCESSOR  = abs_path("$SCRIPT_DIR/../lazysite-processor.pl");
my $nocache    = 1;
my $ERR_FILE   = "/tmp/lazysite-server-$$.err";
my $LOG_FILE   = '';

END { unlink $ERR_FILE if -f $ERR_FILE }

# --- Parse arguments ---

my $show_help = 0;

while ( @ARGV ) {
    my $arg = shift @ARGV;
    if    ( $arg eq '--port' )      { $PORT      = shift @ARGV; }
    elsif ( $arg eq '--docroot' )   { $DOCROOT   = abs_path( shift @ARGV ); }
    elsif ( $arg eq '--processor' ) { $PROCESSOR = abs_path( shift @ARGV ); }
    elsif ( $arg eq '--cache' )     { $nocache   = 0; }
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
  --debug             Enable DEBUG level logging
  --log       FILE    Write log lines to file in addition to terminal
  --help              Show this help

No arguments needed to browse the starter site:

  cd /path/to/lazysite
  perl tools/lazysite-server.pl
  open http://localhost:8080/

To serve your own site:

  perl tools/lazysite-server.pl --docroot /path/to/your/public_html
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

# --- Seed auth files from examples if needed ---

my $auth_dir = "$DOCROOT/lazysite/auth";
{
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
if ( ! -f $conf_target && -f $conf_source ) {
    require File::Copy;
    require File::Path;
    File::Path::make_path( "$DOCROOT/lazysite" );
    File::Copy::copy( $conf_source, $conf_target );
    print "  seeded: lazysite/lazysite.conf\n";
}

# Copy manager CSS to web-accessible path
{
    my $src = "$DOCROOT/lazysite/themes/manager/assets/manager.css";
    my $dst = "$DOCROOT/manager/assets/manager.css";
    if ( -f $src ) {
        require File::Path;
        require File::Copy;
        File::Path::make_path("$DOCROOT/manager/assets") unless -d "$DOCROOT/manager/assets";
        File::Copy::copy( $src, $dst );
    }
}

# Seed form config from .example files if missing
{
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
if ( ! -f $nav_target && -f $nav_source ) {
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
    if ( $method eq 'GET' && -f $file_path && $file_path !~ /\.(md|url|tt|conf)$/
         && !( $file_path =~ /\.html$/ && ( -f ($file_path =~ s/\.html$/.md/r) || -f ($file_path =~ s/\.html$/.url/r) ) ) ) {
        serve_static( $client, $file_path, $method, $uri, $t0 );
        return;
    }

    # Determine which script to run
    my $script = $PROCESSOR;
    my $auth_script  = abs_path("$SCRIPT_DIR/../lazysite-auth.pl");
    my $manager_api  = abs_path("$SCRIPT_DIR/../lazysite-manager-api.pl");
    my $auth_users   = "$DOCROOT/lazysite/auth/users";
    my $use_auth     = -f $auth_users && -f $auth_script;

    # Route /cgi-bin/*.pl requests to scripts at repo root
    if ( $uri =~ m{^/cgi-bin/(lazysite-[\w-]+\.pl)} ) {
        my $cgi_script = abs_path("$SCRIPT_DIR/../$1");
        $script = $cgi_script if $cgi_script && -f $cgi_script;
    }
    elsif ( $use_auth ) {
        # Route all page requests through auth wrapper
        $script = $auth_script;
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
        LAZYSITE_PROCESSOR  => $PROCESSOR,
        ( $ENV{LAZYSITE_LOG_LEVEL}  ? ( LAZYSITE_LOG_LEVEL  => $ENV{LAZYSITE_LOG_LEVEL}  ) : () ),
        ( $ENV{LAZYSITE_LOG_FORMAT} ? ( LAZYSITE_LOG_FORMAT => $ENV{LAZYSITE_LOG_FORMAT} ) : () ),
    );

    # Pass cookie header
    if ( $req_headers{'cookie'} ) {
        $env{HTTP_COOKIE} = $req_headers{'cookie'};
    }

    local @ENV{ keys %env } = values %env;

    my $output;
    if ( length $post_body ) {
        my $post_file = "/tmp/lazysite-post-$$.dat";
        # L-7: previously this open() was unchecked — silent data loss if
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

    # Send HTTP response
    my $body   = Encode::encode_utf8($output);
    my $length = length($body);

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
