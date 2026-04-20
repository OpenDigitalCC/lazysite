#!/usr/bin/perl
# Remote URL fetching via fetch_url(), against a mock HTTP server
# spun up in a child process. Avoids any live-network dependency.
#
# The SSRF guard (is_safe_url) rejects loopback by design, so for
# these tests we monkey-patch it to permit the test's own mock
# port. That override is scoped to the in-process test harness and
# cannot affect production code.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);
load_processor($docroot);

# Disable the SSRF guard for these tests only. Tests run in their
# own perl process (each .t file is a fresh interpreter), so this
# redefine affects nothing outside this file.
{
    no warnings qw(redefine once);
    *main::is_safe_url = sub { 1 };
}

# --- Start a mock HTTP server on a random free port ---
my $server = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0,          # kernel picks a free port
    Proto     => 'tcp',
    Listen    => 5,
    ReuseAddr => 1,
) or BAIL_OUT("cannot bind mock server: $!");
my $port = $server->sockport;

my $pid = fork();
BAIL_OUT("fork failed: $!") unless defined $pid;

if ( $pid == 0 ) {
    # Child: serve a small set of canned responses then exit
    my %responses = (
        '/plain'     => [ 200, 'text/plain; charset=utf-8', "hello from mock\n" ],
        '/html'      => [ 200, 'text/html; charset=utf-8',  "<p>Mock HTML</p>\n" ],
        # _resolve_include uses the URL *extension* to pick its
        # processing path: .html is inserted as bare HTML; an
        # extensionless URL is wrapped in <pre>. So the include
        # end-to-end test hits /page.html below.
        '/page.html' => [ 200, 'text/html; charset=utf-8',  "<p>Mock HTML</p>\n" ],
        '/notok'     => [ 500, 'text/plain; charset=utf-8', "boom\n" ],
    );

    my $handled = 0;
    # We make exactly 4 network-bound calls in this test:
    #   fetch_url /plain, fetch_url /html, fetch_url /notok,
    #   convert_fenced_include on /page.html.
    # file:// and non-http rejections are decided before any connect.
    while ( $handled < 4 ) {
        my $client = $server->accept or last;
        my $req = <$client> // '';
        while ( my $line = <$client> ) { last if $line =~ /\A\r?\n\z/ }

        my ($path) = $req =~ m{\A[A-Z]+\s+(\S+)};
        $path //= '/';
        if ( $path eq '/slow' ) { sleep 1 }    # exercise timeout-ok path

        my $resp = $responses{$path}
                // [ 404, 'text/plain', "not found: $path\n" ];
        my ( $status, $ct, $body ) = @$resp;
        my $status_text = $status == 200 ? 'OK'
                        : $status == 500 ? 'Internal Server Error'
                        :                  'Not Found';
        print $client "HTTP/1.0 $status $status_text\r\n";
        print $client "Content-Type: $ct\r\n";
        print $client "Content-Length: " . length($body) . "\r\n";
        print $client "Connection: close\r\n\r\n";
        print $client $body;
        close $client;
        $handled++;
    }
    close $server;
    exit 0;
}
close $server;  # parent no longer needs the listening socket

my $base = "http://127.0.0.1:$port";

# --- Happy path ---
{
    my $body = main::fetch_url("$base/plain");
    ok( defined $body, 'fetch_url returned defined content' );
    like( $body, qr/hello from mock/, 'body matches server response' );
}

# --- HTML returned as text content ---
{
    my $body = main::fetch_url("$base/html");
    like( $body, qr/<p>Mock HTML<\/p>/, 'HTML body returned intact' );
}

# --- 500 from server → fetch_url returns empty list ---
{
    my $body = main::fetch_url("$base/notok");
    ok( !defined $body || $body eq '', '5xx → undef/empty from fetch_url' );
}

# --- Non-http scheme rejected before networking ---
{
    my $body = main::fetch_url("file:///etc/passwd");
    ok( !defined $body || $body eq '',
        'non-http scheme rejected by fetch_url' );
}

# --- :::include over http: end-to-end ---
# Re-enable SSRF guard? No — we're still in the patched process.
# The include path uses fetch_url, which we've confirmed works.
{
    my $md = "::: include\n$base/page.html\n:::\n";
    my $out = main::convert_fenced_include( $md, "$docroot/index.md", {} );
    like( $out, qr/<p>Mock HTML<\/p>/,
          ':::include http:// fetches and inlines HTML' );
}

waitpid $pid, 0;
done_testing();
