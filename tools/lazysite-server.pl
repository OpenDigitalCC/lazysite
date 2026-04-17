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
    eval "require $mod";
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

# --- Defaults ---

my $SCRIPT_DIR = dirname( abs_path($0) );
my $PORT       = 8080;
my $DOCROOT    = abs_path("$SCRIPT_DIR/../starter");
my $PROCESSOR  = abs_path("$SCRIPT_DIR/../lazysite-processor.pl");
my $nocache    = 1;
my $ERR_FILE   = "/tmp/lazysite-server-$$.err";

END { unlink $ERR_FILE if -f $ERR_FILE }

# --- Parse arguments ---

my $show_help = 0;

while ( @ARGV ) {
    my $arg = shift @ARGV;
    if    ( $arg eq '--port' )      { $PORT      = shift @ARGV; }
    elsif ( $arg eq '--docroot' )   { $DOCROOT   = abs_path( shift @ARGV ); }
    elsif ( $arg eq '--processor' ) { $PROCESSOR = abs_path( shift @ARGV ); }
    elsif ( $arg eq '--cache' )     { $nocache   = 0; }
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

# --- Start server ---

my $cache_label = $nocache ? 'disabled (pass --cache to enable)' : 'enabled';

print "lazysite dev server\n";
print "  processor: $PROCESSOR\n";
print "  docroot:   $DOCROOT\n";
print "  url:       http://localhost:$PORT/\n";
print "  cache:     $cache_label\n";
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

    # Drain headers
    while ( my $header = <$client> ) {
        last if $header =~ /^\r?\n$/;
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
    if ( -f $file_path && $file_path !~ /\.(md|url|tt|conf)$/
         && !( $file_path =~ /\.html$/ && ( -f ($file_path =~ s/\.html$/.md/r) || -f ($file_path =~ s/\.html$/.url/r) ) ) ) {
        serve_static( $client, $file_path, $method, $uri, $t0 );
        return;
    }

    # Invoke processor
    my %env = (
        DOCUMENT_ROOT    => $DOCROOT,
        REDIRECT_URL     => $uri,
        REQUEST_URI      => $raw_uri,
        QUERY_STRING     => $query_string,
        REQUEST_SCHEME   => 'http',
        SERVER_NAME      => 'localhost',
        SERVER_PORT      => $PORT,
        LAZYSITE_NOCACHE => $nocache,
    );

    my $env_prefix = join ' ', map { "$_=\Q$env{$_}\E" } sort keys %env;
    my $output = qx($env_prefix perl \Q$PROCESSOR\E 2>$ERR_FILE);

    # Print any stderr to terminal
    if ( -s $ERR_FILE ) {
        open my $err, '<', $ERR_FILE;
        print while <$err>;
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
    my $ms     = $has_hires ? int( ( Time::HiRes::time() - $t0 ) * 1000 ) : 0;
    my $timing = $has_hires ? " (${ms}ms)" : '';
    print "$method $uri -> $status$timing\n";
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

        my $ms     = $has_hires ? int( ( Time::HiRes::time() - $t0 ) * 1000 ) : 0;
        my $timing = $has_hires ? " (${ms}ms)" : '';
        print "$method $uri -> 500 Internal Server Error$timing\n";
        return;
    };
    local $/;
    my $body = <$fh>;
    close $fh;

    my $length = length($body);

    print $client "HTTP/1.0 200 OK\r\n";
    print $client "Content-Type: $content_type\r\n";
    print $client "Content-Length: $length\r\n";
    print $client "Connection: close\r\n";
    print $client "\r\n";
    print $client $body;

    print "$method $uri -> 200 OK (static)\n";
}
