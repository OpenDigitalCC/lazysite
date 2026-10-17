#!/usr/bin/perl
# SM1120 (follow-up to SM1113): an engine-served static says when it changed.
#
# The finding, 2026-10-17, on SM1113: "If-Range always gets the whole file. The
# server's only validator is the weak ETag, which never passes If-Range's strong
# comparison, and it sends no Last-Modified." The release manager: "yes to
# Last-Modified".
#
# This drives the processor CGI, as t/unit/processor/130 does.
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
make_path("$docroot/lazysite/auth");
sub write_acls {
    my ($map) = @_;
    open my $fh, '>', "$docroot/lazysite/auth/acls.json" or die $!;
    print {$fh} encode_json($map);
    close $fh;
    return;
}
write_acls( {} );

my $BODY = join '', map { sprintf '%04d', $_ } 0 .. 249;
my $SIZE = length $BODY;
make_path("$docroot/lazysite-assets/media");
my $OLD = 1_700_000_000;    # Tue, 14 Nov 2023 22:13:20 GMT
my $OLD_DATE = 'Tue, 14 Nov 2023 22:13:20 GMT';
my %path;
for my $name (qw(clip.mp4 fresh.mp4 private.mp4)) {
    $path{$name} = "$docroot/lazysite-assets/media/$name";
    open my $fh, '>', $path{$name} or die $!;
    binmode $fh;
    print {$fh} $BODY;
    close $fh;
}
utime $OLD, $OLD, $path{'clip.mp4'}    or die $!;
utime $OLD, $OLD, $path{'private.mp4'} or die $!;

# A file whose mtime is not yet behind the clock: a date naming it is a WEAK
# validator (RFC 9110 13.1.5), because a second write inside the same second
# would carry the same date. The future keeps this independent of when in the
# second the test runs.
my $FRESH = time() + 60;
utime $FRESH, $FRESH, $path{'fresh.mp4'} or die $!;
my @D = qw(Sun Mon Tue Wed Thu Fri Sat);
my @M = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
my @g = gmtime $FRESH;
my $FRESH_DATE = sprintf '%s, %02d %s %04d %02d:%02d:%02d GMT',
    $D[ $g[6] ], $g[3], $M[ $g[4] ], $g[5] + 1900, @g[ 2, 1, 0 ];

sub get {
    my ( $range, %env ) = @_;
    my $uri = delete $env{uri} // '/lazysite-assets/media/clip.mp4';
    my $out = run_processor( $docroot, $uri,
        HTTP_RANGE => $range,
        HTTP_IF_NONE_MATCH => undef, HTTP_IF_MODIFIED_SINCE => undef,
        HTTP_IF_RANGE => undef,
        %env );
    my ( $head, $body ) = split /\r?\n\r?\n/, $out, 2;
    my %h;
    for ( split /\r?\n/, $head // '' ) {
        $h{ lc $1 } = $2 if /^([^:]+):\s*(.*)$/;
    }
    return { head => $head // '', h => \%h, body => $body // '',
        status => ( ( $h{status} // '' ) =~ /^(\d{3})/ )[0] // '' };
}

subtest 'Last-Modified is the file mtime, on 200, 206, 416, 304 and HEAD' => sub {
    my $etag = get(undef)->{h}{etag};
    my %case = (
        '200'  => get(undef),
        '206'  => get('bytes=0-99'),
        '416'  => get('bytes=5000-'),
        '304'  => get( undef, HTTP_IF_NONE_MATCH => $etag ),
        'HEAD' => get( undef, REQUEST_METHOD => 'HEAD' ),
    );
    for my $k ( sort keys %case ) {
        is( $case{$k}{h}{'last-modified'}, $OLD_DATE,
            "$k: Last-Modified is the mtime as an IMF-fixdate" )
            or diag( $case{$k}{head} );
    }
    is( $case{'304'}{status}, '304', 'the 304 case is a 304' );
};

subtest 'an ACL-governed file says it too, and is still no-store' => sub {
    write_acls( { 'lazysite-assets/media/private.mp4' => { read => ['alice'] } } );
    my $r = get( undef, uri => '/lazysite-assets/media/private.mp4',
        LAZYSITE_AUTH_TRUSTED => '1', HTTP_X_REMOTE_USER => 'alice' );
    is( $r->{status}, '200', 'the named reader is served' );
    is( $r->{h}{'last-modified'}, $OLD_DATE, 'with its date' );
    is( $r->{h}{'cache-control'}, 'no-store', 'and the cache rule is unchanged' );
    my $anon = get( undef, uri => '/lazysite-assets/media/private.mp4' );
    ok( !defined $anon->{h}{'last-modified'}, 'a refused reader is told nothing of the file' );
    write_acls( {} );
};

subtest 'If-Modified-Since: 304 when the file is not newer, 200 when it is' => sub {
    for my $date ( $OLD_DATE, 'Wed, 15 Nov 2023 22:13:20 GMT' ) {
        my $r = get( undef, HTTP_IF_MODIFIED_SINCE => $date );
        is( $r->{status}, '304', "IMS: $date -> 304" ) or diag( $r->{head} );
        is( $r->{body}, '', 'no body' );
        is( $r->{h}{'last-modified'}, $OLD_DATE, 'the 304 carries Last-Modified' );
        like( $r->{h}{etag} // '', qr{^W/"}, 'and the ETag' );
    }
    my $r = get( undef, HTTP_IF_MODIFIED_SINCE => 'Tue, 14 Nov 2023 22:13:19 GMT' );
    is( $r->{status}, '200', 'a client copy one second older gets the file' );
    is( $r->{body}, $BODY, 'whole' );

    $r = get( undef, HTTP_IF_MODIFIED_SINCE => 'yesterday-ish' );
    is( $r->{status}, '200', 'a date that does not parse is ignored' );

    my $h = get( undef, HTTP_IF_MODIFIED_SINCE => $OLD_DATE, REQUEST_METHOD => 'HEAD' );
    is( $h->{status}, '304', 'HEAD agrees with GET' );
};

subtest 'If-None-Match is primary over If-Modified-Since (RFC 9110 13.2.2)' => sub {
    # A non-matching If-None-Match means "send it", whatever the date says.
    my $r = get( undef, HTTP_IF_NONE_MATCH => 'W/"0-0"',
        HTTP_IF_MODIFIED_SINCE => $OLD_DATE );
    is( $r->{status}, '200', 'a stale ETag beats a current date' ) or diag( $r->{head} );
    # And a matching one is a 304 whatever the date says.
    my $etag = get(undef)->{h}{etag};
    $r = get( undef, HTTP_IF_NONE_MATCH => $etag,
        HTTP_IF_MODIFIED_SINCE => 'Thu, 01 Jan 2004 00:00:00 GMT' );
    is( $r->{status}, '304', 'a current ETag beats an old date' );
};

subtest 'If-Range with a date' => sub {
    my $r = get( 'bytes=0-99', HTTP_IF_RANGE => $OLD_DATE );
    is( $r->{status}, '206', 'the exact date of an old file honours the range' )
        or diag( $r->{head} );
    is( $r->{body}, substr( $BODY, 0, 100 ), 'with those bytes' );
    is( $r->{h}{'content-range'}, "bytes 0-99/$SIZE", 'and Content-Range' );

    $r = get( 'bytes=0-99', HTTP_IF_RANGE => 'Wed, 15 Nov 2023 22:13:20 GMT' );
    is( $r->{status}, '200', 'a different date (even a later one) gets the whole file' );
    is( $r->{body}, $BODY, 'whole' );

    $r = get( 'bytes=0-99', HTTP_IF_RANGE => 'not a date' );
    is( $r->{status}, '200', 'an unparsable If-Range gets the whole file' );

    $r = get( 'bytes=0-99', uri => '/lazysite-assets/media/fresh.mp4',
        HTTP_IF_RANGE => $FRESH_DATE );
    is( $r->{h}{'last-modified'}, $FRESH_DATE, 'the fresh file names its date' );
    is( $r->{status}, '200',
        'a date that is not yet a second behind the clock is weak: whole file' );

    my $etag = get(undef)->{h}{etag};
    $r = get( 'bytes=0-99', HTTP_IF_RANGE => $etag );
    is( $r->{status}, '200', 'an entity-tag If-Range still gets the whole file' );

    my $h = get( 'bytes=0-99', HTTP_IF_RANGE => $OLD_DATE, REQUEST_METHOD => 'HEAD' );
    is( $h->{status}, '206', 'HEAD agrees with GET' );
    is( $h->{h}{'content-range'}, "bytes 0-99/$SIZE", 'including Content-Range' );
    is( $h->{body}, '', 'and sends no body' );
};

done_testing();
