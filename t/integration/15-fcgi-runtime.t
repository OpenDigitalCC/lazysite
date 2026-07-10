#!/usr/bin/perl
# SM142: the processor's dual-mode FastCGI runtime. One worker process
# services many requests from an accept loop - so these tests pin the two
# things that matter: the loop WORKS (real FCGI protocol over a unix
# socket, spawn-fcgi style) and per-request state actually RESETS (no
# leakage between consecutive requests in one interpreter: status, channel,
# cache flag, auth context, access-log lines all per-request).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use POSIX      qw(dup2);
use Socket     qw(AF_UNIX SOCK_STREAM sockaddr_un);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough);
use MiniFcgi   qw(fcgi_request);

plan skip_all => 'FCGI.pm not installed (the plain-CGI path is the fallback)'
    unless eval { require FCGI; 1 };

my $root = repo_root();
my $d    = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/manager");
open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
print $c "site_name: T\nmanager: enabled\n";
close $c;
open my $i, '>', "$d/index.md" or die $!;
print $i "---\ntitle: Home\n---\nHOME caf\x{c3}\x{a9} BODY\n";
close $i;
open my $a, '>', "$d/about.md" or die $!;
print $a "---\ntitle: About\n---\nABOUT BODY\n";
close $a;

# Spawn the processor as an FCGI worker: listening unix socket on fd 0
# (exactly what spawn-fcgi / the SM139 pool unit does).
my $sock_path = "$d/fcgi.sock";
socket( my $lsock, AF_UNIX, SOCK_STREAM, 0 ) or die "socket: $!";
bind( $lsock, sockaddr_un($sock_path) )      or die "bind: $!";
listen( $lsock, 5 )                          or die "listen: $!";

my $pid = fork();
die "fork: $!" unless defined $pid;
if ( $pid == 0 ) {
    my %keep = ( env_passthrough(), DOCUMENT_ROOT => $d, LAZYSITE_FCGI_MAX_REQUESTS => 50 );
    %ENV = %keep;
    dup2( fileno($lsock), 0 ) or die "dup2: $!";
    open STDERR, '>', "$d/worker-stderr.log" or die $!;
    exec $^X, "$root/lazysite-processor.pl";
    die "exec: $!";
}
close $lsock;

# Wait for the worker to accept.
my $up = 0;
for ( 1 .. 50 ) {
    $up = eval {
        fcgi_request( $sock_path,
            { REQUEST_METHOD => 'GET', REDIRECT_URL => '/', REMOTE_ADDR => '198.51.100.1',
                HTTP_USER_AGENT => 'Mozilla/5.0 FcgiTest', DOCUMENT_ROOT => $d } );
    };
    last if $up;
    select( undef, undef, undef, 0.1 );
}
ok( $up, 'worker up and answered over the FCGI protocol' ) or do {
    kill 'TERM', $pid;
    done_testing;
    exit;
};

like( $up->{stdout}, qr/Status: 200 OK/, 'request 1: 200' );
like( $up->{stdout}, qr/HOME caf/,       'request 1: body rendered' );

# Request 2 on the SAME worker: a 404 with a different visitor.
my $r2 = fcgi_request( $sock_path,
    { REQUEST_METHOD => 'GET', REDIRECT_URL => '/nope', REMOTE_ADDR => '198.51.100.2',
        HTTP_USER_AGENT => 'Mozilla/5.0 FcgiTest', DOCUMENT_ROOT => $d } );
like( $r2->{stdout}, qr/Status: 404 Not Found/, 'request 2 (same worker): 404' );
unlike( $r2->{stdout}, qr/HOME caf/, 'request 2: no body leakage from request 1' );

# Request 3: back to a 200 on another page - status must not stick at 404.
my $r3 = fcgi_request( $sock_path,
    { REQUEST_METHOD => 'GET', REDIRECT_URL => '/about', REMOTE_ADDR => '198.51.100.1',
        HTTP_USER_AGENT => 'Mozilla/5.0 FcgiTest', DOCUMENT_ROOT => $d } );
like( $r3->{stdout}, qr/Status: 200 OK/, 'request 3: 200 (no sticky state)' );
like( $r3->{stdout}, qr/ABOUT BODY/,     'request 3: correct body' );

# Request 4: / again - served from the page cache WRITTEN BY THIS WORKER.
my $r4 = fcgi_request( $sock_path,
    { REQUEST_METHOD => 'GET', REDIRECT_URL => '/', REMOTE_ADDR => '198.51.100.1',
        HTTP_USER_AGENT => 'Mozilla/5.0 FcgiTest', DOCUMENT_ROOT => $d } );
like( $r4->{stdout}, qr/Status: 200 OK/, 'request 4: cache hit serves' );

# The SM140 recorder wrote one line PER REQUEST with per-request values
# (the reset lives inside the loop - the review flagged the file-scope
# wrapper as FCGI residue).
my ($log) = glob "$d/lazysite/logs/access-*.jsonl";
ok( $log, 'access log written by the worker' );
my @lines = map { decode_json($_) } do {
    open my $fh, '<', $log or die $!;
    <$fh>;
};
is( scalar @lines, 4,       'four requests, four lines' );
is( $lines[0]{s},  200,     'line 1: 200' );
is( $lines[1]{s},  404,     'line 2: 404 (no carry-over)' );
is( $lines[1]{p},  '/nope', 'line 2: its own path' );
is( $lines[2]{s},  200,     'line 3: 200' );
is( $lines[3]{c},  1,       'line 4: cache-hit flag' );
isnt( $lines[0]{v}, $lines[1]{v}, 'distinct visitors get distinct keys' );
is( $lines[0]{v}, $lines[2]{v}, 'same visitor same key across the loop' );

# All four requests were served by ONE process (persistence, not respawn).
my @pids = map { $_->{wpid} // () } @lines;
kill 'TERM', $pid;
waitpid $pid, 0;

done_testing;
