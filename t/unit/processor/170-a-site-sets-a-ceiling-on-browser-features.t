#!/usr/bin/perl
# SM1294 (ruled 2026-10-23, #29): A SITE MAY SET A CEILING ON THE BROWSER
# FEATURES ITS PAGES ASK FOR, AND NEED NOT.
#
# lazysite.conf's permissions_policy_allow is optional. Absent, a page asks as
# SM1266 made it: `geolocation: self` sends geolocation=(self) on https. Present,
# only a listed feature can be asked for: an unlisted one stays =(), the default,
# and validate warns naming the setting. Before this the key was an ordinary site
# variable and changed nothing, so a page asking for an unlisted feature got it.
# Asserted on the wire through the processor, through validate_content and
# `lazysite validate`, in page_status's reader, and in `lazysite check`.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root run_processor setup_test_site site_tempdir run_child);
use Lazysite::Validate ();

my $root = repo_root();
my $d    = site_tempdir();
setup_test_site($d);
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
my $BASE = "site_name: Test\nsite_url: http://localhost\nlayout: test\n";
sub conf { spit( "$d/lazysite/lazysite.conf", $BASE . ( defined $_[0] ? "permissions_policy_allow: $_[0]\n" : '' ) ) }

my $CLOCK = "---\ntitle: Clock in\ngeolocation: self\ncamera: self\n---\nWhere are you?\n";
spit( "$d/clock.md", $CLOCK );
spit( "$d/mic.md",   "---\ntitle: Mic\nmicrophone: self\n---\nx\n" );

my $DEFAULT = 'accelerometer=(), browsing-topics=(), camera=(), display-capture=(), '
    . 'geolocation=(), gyroscope=(), magnetometer=(), microphone=(), midi=(), payment=(), '
    . 'usb=(), xr-spatial-tracking=()';
sub with { my $p = $DEFAULT; $p =~ s/(?<![a-z-])\Q$_\E=\(\)/$_=(self)/ for @_; return $p }
sub policy {
    my ($uri) = @_;
    my $out = run_processor( $d, $uri, HTTPS => 'on' );
    my ($l) = $out =~ /^Permissions-Policy:\s*(.*?)\r?$/mi;
    return $l;
}
sub warned {
    my ( $content, $kind ) = @_;
    my $r = Lazysite::Validate::validate_content( content => $content, docroot => $d );
    return ( $r, [ grep { $_->{kind} eq $kind } @{ $r->{warnings} } ] );
}

subtest 'absent or empty: nothing changes' => sub {
    for my $c ( undef, '', '  ' ) {
        conf($c);
        my $l = defined $c ? "'$c'" : 'absent';
        is( policy('/clock'), with(qw(camera geolocation)), "$l: the page gets what it asks for" );
        my ( $r, $w ) = warned( $CLOCK, 'permission-above-site-ceiling' );
        ok( $r->{valid}, "$l: the page is valid" );
        is( scalar @$w, 0, "$l: and nothing is warned" );
        is_deeply( [ Lazysite::Validate::permissions_allowed( ( Lazysite::Validate::split_front_matter($CLOCK) )[0],
                    Lazysite::Validate::site_permissions_ceiling("$d/lazysite") ) ],
            [qw(camera geolocation)], "$l: page status shows both" );
    }
};

subtest 'a list: only what it names can be asked for' => sub {
    conf('camera');
    is( policy('/clock'), with('camera'), 'camera listed: camera=(self), geolocation stays =()' );
    is( policy('/mic'),   $DEFAULT,      'microphone unlisted: the default header' );
    my ( $r, $w ) = warned( $CLOCK, 'permission-above-site-ceiling' );
    ok( $r->{valid}, 'the page is still valid: a warning never blocks a save' );
    is( scalar @$w,    1,             'one warning' );
    is( $w->[0]{key}, 'geolocation', '...for the unlisted feature' );
    like( $w->[0]{message}, qr/permissions_policy_allow lists only camera, so the page keeps geolocation=\(\)/,
        '...naming the site setting and what it lists' );
    is_deeply( [ Lazysite::Validate::permissions_allowed( ( Lazysite::Validate::split_front_matter($CLOCK) )[0],
                Lazysite::Validate::site_permissions_ceiling("$d/lazysite") ) ],
        ['camera'], 'page status shows only the listed one' );

    conf('Geolocation, camera');
    is( policy('/clock'), with(qw(camera geolocation)), 'both listed, any case: both (self)' );
    my ( undef, $none ) = warned( $CLOCK, 'permission-above-site-ceiling' );
    is( scalar @$none, 0, '...and nothing warned' );
};

subtest 'none lets no page ask; payment and browsing-topics never widen it' => sub {
    conf('none');
    is( policy('/clock'), $DEFAULT, 'none: the default header' );
    my ( undef, $w ) = warned( $CLOCK, 'permission-above-site-ceiling' );
    is( scalar @$w, 2, 'both features warned' );
    like( $w->[0]{message}, qr/permissions_policy_allow is none/, '...saying the list is none' );

    conf('payment, browsing-topics, geolocaton');
    is( policy('/clock'), $DEFAULT, 'only names that are no askable feature: nothing can be asked for' );
    spit( "$d/pay.md", "---\ntitle: Pay\nbrowsing-topics: self\n---\nx\n" );
    unlike( run_processor( $d, '/pay', HTTPS => 'on' ), qr/browsing-topics=\(self\)/,
        'a listed browsing-topics grants nothing' );
};

subtest 'it is per site: a domain alias cannot override it' => sub {
    spit( "$d/lazysite/lazysite.conf", $BASE . "permissions_policy_allow: camera\nalias_hosts: b.example\n"
            . "alias.b.example.permissions_policy_allow: camera, geolocation\n" );
    my $out = run_processor( $d, '/clock', HTTPS => 'on', HTTP_HOST => 'b.example', SERVER_NAME => 'b.example' );
    my ($l) = $out =~ /^Permissions-Policy:\s*(.*?)\r?$/mi;
    is( $l, with('camera'), 'the alias line is not read: still camera only' );
};

subtest 'lazysite validate warns too' => sub {
    conf('camera');
    my $r = run_child( [ $^X, "-I$root/lib", "$root/tools/lazysite-validate.pl", '--docroot', $d, "$d/clock.md" ],
        stderr => 'merge' );
    is( $r->{status} >> 8, 0, 'the page passes' ) or diag $r->{out};
    like( $r->{out}, qr/geolocation: self' grants nothing on this site/, 'and the warning is printed' );
};

subtest 'lazysite check names an entry no page can ask for' => sub {
    my $tool = "$root/tools/lazysite-check.pl";
    my $run  = sub { run_child( [ $^X, "-I$root/lib", $tool, '--docroot', $d ], stderr => 'merge' )->{out} };
    conf(undef);
    unlike( $run->(), qr/permissions_policy_allow/, 'no ceiling: nothing said' );
    conf('camera, payment, wibble');
    like( $run->(), qr/\[\s*warn\s*\].*permissions_policy_allow lists 2 entries that no page can ask for: payment, wibble/,
        'a refused entry: warned, by name' );
    conf('camera');
    like( $run->(), qr/\[\s*ok\s*\].*pages may ask only for the browser features permissions_policy_allow lists: camera/,
        'a clean list: said' );
};

done_testing;
