#!/usr/bin/perl
# SM1113 (and SM1112): an engine-served static answers a byte range, with the
# type of the media it is.
#
# The field report, 2026-10-16, publishing interface clips to xisl.com (0.14.4),
# the same range behaviour on edge (0.15.5):
#
#   "A request with `Range: bytes=0-99` gets `200` and the whole file, with no
#   `Accept-Ranges` header, on xisl.com (a 3.2 MB mp4 and a png) and on edge (a
#   favicon). Every response carries `x-lazysite-front: hestia-proxy/acl`.
#   Safari and iOS will not play a <video> whose server ignores Range"
#
# and, for the type: "`.mp4` / `.webm` are served as `application/octet-stream`"
# beside nosniff, while .png and .jpg get theirs.
#
# `hestia-proxy/acl` is the SM283 proxy template, which on a site with an ACL
# store hands EVERY static to Apache, which hands it to lazysite-auth.pl, which
# execs the processor - so the answer is _serve_content_static's, and this
# drives the processor CGI the way that chain does. t/integration/260 drives the
# same chain through a real Apache.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir setup_test_site run_processor);

my $docroot = site_tempdir();
setup_test_site($docroot);

# SM223: the engine serves statics only when the site has an ACL store, which
# is exactly the condition under which the proxy template sends them here.
make_path("$docroot/lazysite/auth");
sub write_acls {
    my ($map) = @_;
    open my $fh, '>', "$docroot/lazysite/auth/acls.json" or die $!;
    print {$fh} encode_json($map);
    close $fh;
    return;
}
write_acls( {} );

# 1000 bytes in which every offset is distinguishable, so an off-by-one in
# either end of a range changes the bytes compared.
my $BODY = join '', map { sprintf '%04d', $_ } 0 .. 249;
my $SIZE = length $BODY;
make_path("$docroot/lazysite-assets/media");
for my $name (qw(clip.mp4 private.mp4)) {
    open my $fh, '>', "$docroot/lazysite-assets/media/$name" or die $!;
    binmode $fh;
    print {$fh} $BODY;
    close $fh;
}

sub get {
    my ( $range, %env ) = @_;
    my $out = run_processor( $docroot, $env{uri} // '/lazysite-assets/media/clip.mp4',
        ( defined $range ? ( HTTP_RANGE => $range ) : ( HTTP_RANGE => undef ) ),
        map { $_ eq 'uri' ? () : ( $_ => $env{$_} ) } keys %env );
    my ( $head, $body ) = split /\r?\n\r?\n/, $out, 2;
    my %h;
    for ( split /\r?\n/, $head // '' ) {
        $h{ lc $1 } = $2 if /^([^:]+):\s*(.*)$/;
    }
    return { head => $head // '', h => \%h, body => $body // '',
        status => ( ( $h{status} // '' ) =~ /^(\d{3})/ )[0] // '' };
}

subtest 'the fixture is served at all' => sub {
    my $r = get(undef);
    is( $r->{status}, '200', 'a plain GET is answered by the engine' )
        or diag( $r->{head} );
    is( $r->{body}, $BODY, 'with the whole file' );
};

subtest 'SM1112: media carries its own type' => sub {
    my %want = (
        mp4  => 'video/mp4',
        m4v  => 'video/mp4',
        webm => 'video/webm',
        ogv  => 'video/ogg',
        mp3  => 'audio/mpeg',
        ogg  => 'audio/ogg',
        oga  => 'audio/ogg',
        opus => 'audio/ogg',
        wav  => 'audio/wav',
        m4a  => 'audio/mp4',
        flac => 'audio/flac',
        vtt  => 'text/vtt; charset=utf-8',
    );
    for my $ext ( sort keys %want ) {
        my $p = "$docroot/lazysite-assets/media/t.$ext";
        open my $fh, '>', $p or die $!;
        print {$fh} "x\n";
        close $fh;
        my $r = get( undef, uri => "/lazysite-assets/media/t.$ext" );
        is( $r->{h}{'content-type'}, $want{$ext}, ".$ext is served as $want{$ext}" )
            or diag( 'nosniff is on every engine response, so the type sent is '
                . 'the type a strict client uses: octet-stream is a download.' );
    }
};

subtest 'a full response says ranges are accepted, and how long it is' => sub {
    my $r = get(undef);
    is( $r->{h}{'accept-ranges'}, 'bytes', 'Accept-Ranges: bytes' )
        or diag( 'Without it a media client has no reason to try a range.' );
    is( $r->{h}{'content-length'}, $SIZE, 'Content-Length is the file size' );
};

subtest 'bytes=0-99 is 206 with the first hundred bytes' => sub {
    my $r = get('bytes=0-99');
    is( $r->{status}, '206', '206 Partial Content' ) or diag( $r->{head} );
    is( $r->{h}{'content-range'}, "bytes 0-99/$SIZE", 'Content-Range names the span' );
    is( $r->{h}{'content-length'}, 100, 'Content-Length is the span, not the file' );
    is( $r->{body}, substr( $BODY, 0, 100 ), 'and the body is exactly those bytes' );
    is( $r->{h}{'content-type'}, 'video/mp4', 'the type is the file\'s' );
    is( $r->{h}{'accept-ranges'}, 'bytes', 'Accept-Ranges on the partial too' );
    like( $r->{h}{'etag'} // '', qr{^W/"}, 'the validator is still sent' );
    like( $r->{h}{'cache-control'} // '', qr/no-cache, must-revalidate/,
        'and the SM387 revalidation is unchanged' );
    is( $r->{h}{'x-content-type-options'}, 'nosniff',
        'and the security headers are on the partial' );
};

subtest 'an open range, a suffix, and an end past the file' => sub {
    my $r = get('bytes=900-');
    is( $r->{status}, '206', 'bytes=900- is partial' );
    is( $r->{h}{'content-range'}, "bytes 900-999/$SIZE", 'to the last byte' );
    is( $r->{body}, substr( $BODY, 900 ), 'with the tail' );

    $r = get('bytes=-50');
    is( $r->{status}, '206', 'bytes=-50 is partial' );
    is( $r->{h}{'content-range'}, "bytes 950-999/$SIZE", 'the LAST fifty bytes' );
    is( $r->{body}, substr( $BODY, -50 ), 'and they are the last fifty' );

    $r = get('bytes=990-5000');
    is( $r->{h}{'content-range'}, "bytes 990-999/$SIZE",
        'a last-byte past the end is clamped to the end' );
    is( $r->{h}{'content-length'}, 10, 'and the length follows' );

    $r = get('bytes=-5000');
    is( $r->{status}, '206', 'a suffix longer than the file is still satisfiable' );
    is( $r->{h}{'content-range'}, "bytes 0-999/$SIZE", 'and is the whole file' );
    is( $r->{body}, $BODY, 'every byte' );
};

subtest 'an unsatisfiable range is 416, saying the size' => sub {
    for my $spec ( "bytes=$SIZE-", 'bytes=5000-6000', 'bytes=-0' ) {
        my $r = get($spec);
        is( $r->{status}, '416', "$spec is 416" ) or diag( $r->{head} );
        is( $r->{h}{'content-range'}, "bytes */$SIZE",
            'Content-Range: bytes */size, so the client learns the length' );
        is( $r->{body}, '', 'and no file bytes' );
    }
};

subtest 'what is not a single byte range is answered whole' => sub {
    # RFC 9110 14.2: a server MAY ignore Range. Multi-range would need a
    # multipart/byteranges body; no media client needs it.
    for my $spec ( 'bytes=0-9,20-29', 'bytes=50-10', 'items=0-5', 'bytes=abc' ) {
        my $r = get($spec);
        is( $r->{status}, '200', "$spec gets 200" ) or diag( $r->{head} );
        is( $r->{body}, $BODY, 'with the whole file' );
    }
};

subtest 'If-Range: a weak validator never matches, so the whole file' => sub {
    my $etag = get(undef)->{h}{etag};
    like( $etag, qr{^W/"}, 'the engine\'s ETag is weak' );

    # RFC 9110 13.1.5: If-Range uses the STRONG comparison, which a weak tag
    # never passes, and the engine sends no Last-Modified for a date to match.
    # So a client resuming a stale partial gets a fresh whole - never a range
    # of a file that may have changed under it.
    for my $ir ( $etag, 'Thu, 01 Jan 2026 00:00:00 GMT' ) {
        my $r = get( 'bytes=0-99', HTTP_IF_RANGE => $ir );
        is( $r->{status}, '200', "If-Range: $ir -> 200" );
        is( $r->{body}, $BODY, 'the whole file' );
    }
};

subtest 'a matching If-None-Match is still 304, range or not' => sub {
    my $etag = get(undef)->{h}{etag};
    my $r = get( 'bytes=0-99', HTTP_IF_NONE_MATCH => $etag );
    is( $r->{status}, '304', 'the conditional GET wins over the range' );
};

subtest 'HEAD agrees with GET, and carries no body' => sub {
    for my $spec ( undef, 'bytes=0-99', 'bytes=5000-' ) {
        my $g = get($spec);
        my $h = get( $spec, REQUEST_METHOD => 'HEAD' );
        my $label = $spec // 'no range';
        is( $h->{status}, $g->{status}, "HEAD ($label): the same status" );
        for my $k (qw(content-type content-length content-range accept-ranges etag)) {
            is( $h->{h}{$k}, $g->{h}{$k}, "HEAD ($label): the same $k" );
        }
        is( $h->{body}, '', "HEAD ($label): no body" );
    }
};

subtest 'the ACL is decided before any range is served' => sub {
    write_acls( { 'lazysite-assets/media/private.mp4' => { read => ['alice'] } } );
    my $r = get( 'bytes=0-99', uri => '/lazysite-assets/media/private.mp4' );
    like( $r->{status}, qr/^30[23]$/, 'an anonymous range request is bounced' )
        or diag( $r->{head} );
    unlike( $r->{body}, qr/\A0000/, 'and no protected byte is in it' );

    my $ok = get( 'bytes=0-99', uri => '/lazysite-assets/media/private.mp4',
        LAZYSITE_AUTH_TRUSTED => '1', HTTP_X_REMOTE_USER => 'alice' );
    is( $ok->{status}, '206', 'the reader it names gets the range' );
    is( $ok->{h}{'cache-control'}, 'no-store', 'which a shared cache never stores' );
    write_acls( {} );
};

done_testing();
