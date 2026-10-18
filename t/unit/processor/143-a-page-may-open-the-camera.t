#!/usr/bin/perl
# SM1174 (L-16, ruled 2026-10-18 "Per page, opt-in"): a page's front matter may
# say `camera: self`; that page alone sends camera=(self) on https. Every other
# page keeps camera=().
#
# Before: Permissions-Policy came from one fixed list, camera=() on every
# response, so no page could open a live viewfinder. Asserted here through the
# processor, on the wire: the camera page over https, the same page over plain
# http, a page without the key, and a cached hit of each - a cached page keeps
# its own policy, and a page without the key is never served another's.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(run_processor setup_test_site site_tempdir);
use Lazysite::SecurityHeaders ();

my $d = site_tempdir();
setup_test_site($d);
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
spit( "$d/scan.md",    "---\ntitle: Scan\ncamera: self\n---\nScan here.\n" );
spit( "$d/plain.md",   "---\ntitle: Plain\n---\nNothing special.\n" );
spit( "$d/nofm.md",    "Just text.\ncamera: self\n" );
spit( "$d/refused.md", "---\ntitle: Refused\ncamera: *\n---\nNo.\n" );
spit( "$d/none.md",    "---\ntitle: None\ncamera: none\n---\nNo.\n" );
spit( "$d/body.md",    "---\ntitle: Body\n---\ncamera: self\n" );

sub policy {
    my ($out) = @_;
    my ($l) = $out =~ /^Permissions-Policy:\s*(.*?)\r?$/mi;
    return $l;
}
my @denied = split /, /, ( Lazysite::SecurityHeaders::security_headers() )[3] =~ s/^Permissions-Policy: //r;
( my $base = join ', ', @denied );
( my $withcam = $base ) =~ s/\bcamera=\(\)/camera=(self)/;
isnt( $withcam, $base, 'fixture: the base policy names camera=()' );

sub get { my ( $uri, $https ) = @_; return scalar run_processor( $d, $uri, HTTPS => ( $https ? 'on' : undef ) ) }

subtest 'a camera page over https sends camera=(self) and nothing else changes' => sub {
    my $out = get( '/scan', 1 );
    like( $out, qr/Status: 200/, 'served' );
    is( policy($out), $withcam, 'camera=(self), every other directive as before' );
};
subtest 'the same page over plain http keeps camera=()' => sub {
    is( policy( get( '/scan', 0 ) ), $base, 'camera=()' );
};
subtest 'every other page keeps camera=()' => sub {
    for my $u (qw(/plain /nofm /refused /none /body)) {
        is( policy( get( $u, 1 ) ), $base, "$u over https: camera=()" );
    }
};
subtest 'a cached hit keeps each page its own policy' => sub {
    ok( -f "$d/scan.html" && -f "$d/plain.html", 'both pages are now cached renders' );
    for ( 1 .. 2 ) {
        is( policy( get( '/scan',  1 ) ), $withcam, 'cached camera page: camera=(self)' );
        is( policy( get( '/plain', 1 ) ), $base,    'cached plain page: camera=()' );
        is( policy( get( '/scan',  0 ) ), $base,    'cached camera page over http: camera=()' );
    }
};
subtest 'the ttl cache path keeps it too' => sub {
    spit( "$d/ttl.md", "---\ntitle: Ttl\ncamera: self\nttl: 600\n---\nx\n" );
    get( '/ttl', 1 );
    is( policy( get( '/ttl', 1 ) ), $withcam, 'ttl page, second hit: camera=(self)' );
};

done_testing;
