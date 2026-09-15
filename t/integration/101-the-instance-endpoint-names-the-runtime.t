#!/usr/bin/perl
# SM890: the public instance endpoint names the RUNTIME as well as the version.
#
# WHY IT EXISTS. Two releases running, the decisive question about a site
# reading a stale engine was "is this a pooled worker still holding the old
# code, or something else?" - and both times the agent measuring the estate
# from outside could not answer it. `x-lazysite-front` is the only
# template-shaped marker a request carries and it names the FRONT PROXY: of the
# seven stale sites at 0.14.2, three carried it and four did not, so reading it
# as the backend's unit would have produced a confident wrong answer.
#
# MEASURED, NOT CONFIGURED. The field says what THIS process is, which is the
# only thing a request can honestly report: a FastCGI worker answers "pool", a
# one-shot CGI answers "cgi". A conf file's existence would say what the host
# INTENDED, and the whole point is to tell an outside reader what is actually
# serving them.
#
# THE TEST DRIVES BOTH MODES, because a field hard-coded to "cgi" passes any
# single-mode test. The two readings must DIFFER on the same docroot, which is
# the only assertion that could catch that.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use POSIX      qw(dup2);
use Socket     qw(AF_UNIX SOCK_STREAM sockaddr_un);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir env_passthrough run_processor);
use MiniFcgi   qw(fcgi_request);

my $root = repo_root();
my $d    = site_tempdir();
make_path("$d/lazysite");
open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$c} "site_name: T\n";
close $c;
open my $i, '>', "$d/index.md" or die $!;
print {$i} "---\ntitle: Home\n---\nHOME BODY\n";
close $i;

my $URI = '/.well-known/lazysite-instance.json';

# Split the CGI headers from the body and decode the JSON, so the assertions
# are about a field and not about a substring that could match in a header.
sub body_json {
    my ( $out, $what ) = @_;
    my ($body) = ( $out // '' ) =~ /\r?\n\r?\n(.*)\z/s;
    my $j = eval { decode_json( $body // '' ) };
    ok( $j, "$what: the endpoint answered parseable JSON" )
        or diag( 'got: ' . ( $out // '(nothing)' ) );
    return $j || {};
}

# Scalar context deliberately: run_processor ends in `return qx(...)`, which in
# list context hands back one element PER LINE and silently shifts every
# argument after it.
my $cgi_out = run_processor( $d, $URI );
my $cgi     = body_json( $cgi_out, 'plain CGI' );
is( $cgi->{runtime}, 'cgi', 'a one-shot CGI reports runtime=cgi' );
ok( $cgi->{instance}, 'and still carries the instance id' )
    or diag('The runtime is ADDITIONAL - existing readers key off instance.');

SKIP: {
    skip 'FCGI.pm not installed (the plain-CGI path is the fallback)', 3
        unless eval { require FCGI; 1 };

    # Spawned exactly as the SM139 pool unit spawns it: the listening socket on
    # fd 0, which is what the processor's dual-mode dispatch detects.
    my $sock_path = "$d/fcgi.sock";
    socket( my $lsock, AF_UNIX, SOCK_STREAM, 0 ) or die "socket: $!";
    bind( $lsock, sockaddr_un($sock_path) )      or die "bind: $!";
    listen( $lsock, 5 )                          or die "listen: $!";

    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ( $pid == 0 ) {
        my %keep = ( env_passthrough(), DOCUMENT_ROOT => $d );
        %ENV = %keep;
        dup2( fileno($lsock), 0 ) or die "dup2: $!";
        open STDERR, '>', "$d/worker-stderr.log" or die $!;
        exec $^X, "$root/lazysite-processor.pl";
        die "exec: $!";
    }
    close $lsock;

    my $res = 0;
    for ( 1 .. 50 ) {
        $res = eval {
            fcgi_request( $sock_path,
                { REQUEST_METHOD => 'GET',
                    REDIRECT_URL  => $URI,
                    REMOTE_ADDR   => '198.51.100.1',
                    DOCUMENT_ROOT => $d,
                } );
        };
        last if $res;
        select( undef, undef, undef, 0.1 );
    }
    kill 'TERM', $pid;
    waitpid $pid, 0;

    ok( $res, 'the pooled worker answered over the FCGI protocol' )
        or skip( 'no answer from the worker', 2 );

    my $pool = body_json( $res->{stdout}, 'pooled worker' );
    is( $pool->{runtime}, 'pool', 'a FastCGI worker reports runtime=pool' );
    isnt( $pool->{runtime}, $cgi->{runtime},
        'the two modes give DIFFERENT answers on the same docroot' )
        or diag( 'A constant would satisfy either reading on its own. This is '
            . 'the assertion that says the field is measured.' );
}

done_testing();
