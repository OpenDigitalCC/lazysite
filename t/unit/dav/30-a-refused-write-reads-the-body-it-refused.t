#!/usr/bin/perl
# SM888 A6 / K1: a refused PUT answers 403 whatever the body's size.
#
# THE FIELD REPORT, and it is a strange-looking one: the SAME refused PUT
# answered 403 under about 100 KB and 502 above it. Re-measured on 0.14.2 with
# byte-identical re-PUTs of a site's own live bytes, so the content was not the
# variable. The size was.
#
# THE CAUSE IS ONE MISSING READ. `authorise` refuses before anything touches
# STDIN, and the refusal path never reads the body it refused. The client is
# still sending. Under the socket buffer the whole body fits, the CGI exits,
# and the client sees the 403 it was sent. Above it the client blocks writing
# to a process that has gone away - and the front end, which cannot relay a
# response for a request that never finished, answers 502.
#
# So the status a client sees depends on the size of a body the server decided
# not to look at, and the one status that means "stop asking" is the one it
# stops seeing. An agent reading 502 retries; an agent reading 403 does not.
#
# WHAT THIS TEST MEASURES is the cause rather than the symptom, because the
# symptom needs a front end: the parent writes a body far larger than the pipe
# buffer and checks it could write ALL of it. A child that exits with the body
# unread gives the writer EPIPE, which is exactly what the front end meets.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root setup_dav_site);

my $root = repo_root();
my $site = setup_dav_site();
my $d    = $site->{docroot};

# Well past any pipe buffer (64 KB on Linux) and past the ~100 KB the field
# measured the break at, so a child that does not drain cannot take it.
my $BODY = 'x' x ( 512 * 1024 );

# PUT into the reserved lazysite/ tree: refused by path, before the body is
# looked at, which is the shape the whole item is about.
sub put_refused {
    my ($body) = @_;
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}           = $d;
    $ENV{REQUEST_METHOD}          = 'PUT';
    $ENV{PATH_INFO}               = '/lazysite/lazysite.conf';
    $ENV{SCRIPT_NAME}             = '/dav';
    $ENV{REMOTE_ADDR}             = '127.0.0.1';
    $ENV{HTTP_AUTHORIZATION}      = $site->{auth};
    $ENV{CONTENT_LENGTH}          = length $body;
    $ENV{LAZYSITE_DAV_FAIL_DELAY} = 0;

    # SIGPIPE would kill this test process rather than fail an assertion, and
    # "the test died" is not a measurement.
    local $SIG{PIPE} = 'IGNORE';

    my ( $wtr, $rdr );
    my $err = gensym();
    my $pid = open3( $wtr, $rdr, $err, $^X, "$root/lazysite-dav.pl" );
    binmode $wtr;

    my $written = 0;
    my $broke   = '';
    while ( $written < length $body ) {
        my $n = syswrite $wtr, $body, 65536, $written;
        if ( !defined $n ) { $broke = "$!"; last }
        last unless $n;
        $written += $n;
    }
    close $wtr;
    my $out = do { local $/; <$rdr> };
    my $e   = do { local $/; <$err> };
    waitpid $pid, 0;
    my ($code) = ( $out // '' ) =~ /^Status:\s*(\d+)/;

    return { written => $written, broke => $broke, code => $code,
        stderr => ( $e // '' ) };
}

subtest 'a small refused body: the client sees the refusal' => sub {
    # The half that always worked. Here to show the measure discriminates -
    # without it, a large-body failure could be anything about large bodies.
    my $r = put_refused('x' x 1024);
    is( $r->{code},    403,  'the write is refused' );
    is( $r->{written}, 1024, 'and the whole body was accepted' );
};

subtest 'a large refused body: still 403, and the body is drained' => sub {
    my $r = put_refused($BODY);
    is( $r->{written}, length $BODY,
        'the client could send its whole body' )
        or diag( "wrote $r->{written} of "
            . length($BODY)
            . " bytes; error: $r->{broke}\n"
            . 'A client blocked here is what the front end turns into 502 - '
            . 'the refusal is correct and the caller never sees it.' );
    is( $r->{code}, 403, 'and the refusal is the one the client sees' );
};

done_testing();
