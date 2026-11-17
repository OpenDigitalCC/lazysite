#!/usr/bin/perl
# SM1473: A BINARY UPLOAD OVER WEBDAV WRITES NO WARNINGS.
#
# lazysite-dav.pl's PUT ran the page-parse and address-profile checks on EVERY upload
# through a `<:encoding(UTF-8)` read, so an image, a PDF or an archive was decoded as
# UTF-8 twice and Perl warned once per bad sequence ("UTF-8 \"\x99\" does not map to
# Unicode"): hundreds of MB of error log on a busy site. Those checks judge pages, so
# only a page is read now, raw and then as the processor reads it, and no decoding
# layer is in the way.
#
# Fails on the code before the fix: stderr carries "does not map to Unicode" for the
# binary PUT.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_dav_site run_dav);

my $dav  = setup_dav_site( conf => "webdav_enabled: true\n" );
my $d    = $dav->{docroot};
my %auth = ( HTTP_AUTHORIZATION => $dav->{auth}, REMOTE_ADDR => '127.0.0.1' );

# Bytes that are not UTF-8 anywhere: 0x80-0xFF in every order, repeated.
my $small = join '', map { chr } 0x80 .. 0xFF;
my $large = $small x 2048;    # 256 KiB

for my $c ( [ small => $small ], [ large => $large ] ) {
    my ( $n, $bytes ) = @$c;
    my $r = run_dav( $d, 'PUT', "/img-$n.png", %auth, body => $bytes );
    ok( $r->{code} >= 200 && $r->{code} < 300, "$n binary PUT lands" ) or diag( $r->{raw} );
    ok( -s "$d/img-$n.png" == length $bytes, "$n: every byte is on disk" );
    unlike( $r->{stderr} // '', qr/does not map to Unicode/, "$n: stderr has no UTF-8 warning" );
    is( join( '', grep { !/\[INFO\]/ } split /^/m, $r->{stderr} // '' ), '', "$n: stderr holds only the event log line" );
}

# A form conf and a nav file with bad bytes are judged without a warning too.
{
    my $r = run_dav( $d, 'PUT', '/lazysite/forms/odd.conf', %auth, body => "fields: \x99\xff\n" );
    unlike( $r->{stderr} // '', qr/does not map to Unicode/, 'a form conf with bad bytes: no warning' );
}

# A page that is not UTF-8 is still refused, with no warning.
{
    my $r = run_dav( $d, 'PUT', '/bad.md', %auth, body => "---\ntitle: T\n---\n\x99\xff[% bad\n" );
    is( $r->{code}, 415, 'a .md page with invalid UTF-8 is refused (415)' ) or diag( $r->{raw} );
    ok( !-e "$d/bad.md", 'and nothing landed' );
    unlike( $r->{stderr} // '', qr/does not map to Unicode/, 'with no warning' );
}

# A page that is valid UTF-8 but does not parse is still refused by the page checks.
{
    my $r = run_dav( $d, 'PUT', '/broken.md', %auth, body => "---\ntitle: T\n---\n[% IF %]\n" );
    is( $r->{code}, 415, 'an unparseable page is still refused (415)' ) or diag( $r->{raw} );
    ok( !-e "$d/broken.md", 'and nothing landed' );
    my $ok = run_dav( $d, 'PUT', '/fine.md', %auth, body => "---\ntitle: T\n---\ncaf\xc3\xa9\n" );
    ok( $ok->{code} >= 200 && $ok->{code} < 300, 'a valid UTF-8 page lands' ) or diag( $ok->{raw} );
}

done_testing;
