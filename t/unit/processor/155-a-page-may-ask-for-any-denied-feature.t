#!/usr/bin/perl
# SM1266 (ruled 2026-10-22, #2): a page may ask, on its own, for any feature
# Permissions-Policy denies - `geolocation: self`, `microphone: self` - on
# SM1174's terms for the camera: self only, https only, front matter only, for
# that response alone, and kept per page through the cache.
#
# Before: only `camera: self` relaxed anything; `geolocation: self` was an
# ordinary front-matter key and the page sent geolocation=() like every other.
# Asserted here through the processor, on the wire.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(run_processor setup_test_site site_tempdir);

my $d = site_tempdir();
setup_test_site($d);
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
spit( "$d/clock.md",   "---\ntitle: Clock in\ngeolocation: self\n---\nWhere are you?\n" );
spit( "$d/both.md",    "---\ntitle: Both\nmicrophone: self\ngeolocation: 'self'\n---\nx\n" );
spit( "$d/scan.md",    "---\ntitle: Scan\ncamera: self\n---\nScan here.\n" );
spit( "$d/plain.md",   "---\ntitle: Plain\n---\nNothing special.\n" );
spit( "$d/typo.md",    "---\ntitle: Typo\ngeolocaton: self\n---\nx\n" );
spit( "$d/unknown.md", "---\ntitle: Unknown\nbluetooth: self\nfullscreen: self\n---\nx\n" );
spit( "$d/star.md",    "---\ntitle: Star\ngeolocation: *\n---\nx\n" );
spit( "$d/url.md",     "---\ntitle: Url\nmicrophone: https://example.com\n---\nx\n" );
spit( "$d/none.md",    "---\ntitle: None\ngeolocation: none\n---\nx\n" );
spit( "$d/body.md",    "---\ntitle: Body\n---\ngeolocation: self\n" );

# THE DEFAULT, written out: the line every response sent before a page could
# ask, and the one a page that asks for nothing still sends.
my $DEFAULT = 'accelerometer=(), browsing-topics=(), camera=(), display-capture=(), '
    . 'geolocation=(), gyroscope=(), magnetometer=(), microphone=(), midi=(), payment=(), '
    . 'usb=(), xr-spatial-tracking=()';
sub with { my $p = $DEFAULT; $p =~ s/(?<![a-z-])\Q$_\E=\(\)/$_=(self)/ for @_; return $p }

sub policy {
    my ($out) = @_;
    my ($l) = $out =~ /^Permissions-Policy:\s*(.*?)\r?$/mi;
    return $l;
}
sub get { my ( $uri, $https ) = @_; return scalar run_processor( $d, $uri, HTTPS => ( $https ? 'on' : undef ) ) }

subtest 'a page that asks for nothing sends the default, byte for byte' => sub {
    my $out = get( '/plain', 1 );
    like( $out, qr/Status: 200/, 'served' );
    is( policy($out),                $DEFAULT, 'over https: the pinned line' );
    is( policy( get( '/plain', 0 ) ), $DEFAULT, 'over http: the same' );
};

subtest 'geolocation: self over https sends geolocation=(self) and nothing else changes' => sub {
    is( policy( get( '/clock', 1 ) ), with('geolocation'), 'geolocation=(self), every other feature =()' );
};

subtest 'two features on one page, one of them quoted' => sub {
    is( policy( get( '/both', 1 ) ), with(qw(geolocation microphone)), 'both (self), the rest =()' );
};

subtest 'the camera is as SM1174 made it' => sub {
    is( policy( get( '/scan', 1 ) ), with('camera'), 'camera=(self) and nothing else' );
    is( policy( get( '/scan', 0 ) ), $DEFAULT,       'over http, the default' );
};

subtest 'over plain http the page keeps the default' => sub {
    is( policy( get( '/clock', 0 ) ), $DEFAULT, '/clock' );
    is( policy( get( '/both',  0 ) ), $DEFAULT, '/both' );
};

subtest 'an unknown name, a value other than self, or a body line changes nothing' => sub {
    for my $u (qw(/typo /unknown /star /url /none /body)) {
        is( policy( get( $u, 1 ) ), $DEFAULT, "$u over https: the default" );
    }
};

subtest 'payment cannot be asked for: payment: is the paid-page key' => sub {
    spit( "$d/pay.md", "---\ntitle: Pay\npayment: self\n---\nx\n" );
    my $out = get( '/pay', 1 );
    unlike( $out, qr/payment=\(self\)/, 'no payment=(self)' );
};

subtest 'served from the cache in turn, each page gets its own header' => sub {
    ok( -f "$d/clock.html" && -f "$d/plain.html", 'both pages are now cached renders' );
    for ( 1 .. 2 ) {
        is( policy( get( '/clock', 1 ) ), with('geolocation'), 'cached relaxed page: geolocation=(self)' );
        is( policy( get( '/plain', 1 ) ), $DEFAULT,            'cached plain page: the default' );
        is( policy( get( '/clock', 0 ) ), $DEFAULT,            'cached relaxed page over http: the default' );
        is( policy( get( '/scan',  1 ) ), with('camera'),      'cached camera page: camera=(self) only' );
    }
};

subtest 'the ttl cache path keeps it too' => sub {
    spit( "$d/ttl.md", "---\ntitle: Ttl\nmicrophone: self\nttl: 600\n---\nx\n" );
    get( '/ttl', 1 );
    is( policy( get( '/ttl',   1 ) ), with('microphone'), 'ttl page, second hit: microphone=(self)' );
    is( policy( get( '/plain', 1 ) ), $DEFAULT,           'and the plain page beside it: the default' );
};

done_testing;
