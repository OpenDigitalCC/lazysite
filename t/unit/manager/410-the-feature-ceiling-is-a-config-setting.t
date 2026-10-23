#!/usr/bin/perl
# SM1294 (ruled 2026-10-23, #29): THE SITE'S CEILING ON BROWSER FEATURES IS A
# CONFIG SETTING. config-read surfaces permissions_policy_allow, config-set
# stores a list of features a page can ask for (lower case, each once), `none`,
# or empty (no ceiling), and refuses payment and browsing-topics (rulings 15
# and 16) and anything that is no feature, naming it, and writes nothing then.
# The Config page offers the field. Before this config-set refused the key as
# not settable.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";

my $s = new_site( root => $root );
my $d = $s->docroot;
$s->add_user('boss');
$s->grant( 'boss', 'ops', [qw(ui manage_config)], [qw(ui manage_config)] );
sub call { my ( $a, $b ) = @_; return $s->call( 'boss', $a, ( defined $b ? ( body => $b ) : () ) ) }
sub conf { open my $f, '<', "$d/lazysite/lazysite.conf" or die $!; local $/; return <$f> }
sub set  { return call( 'config-set', { key => 'permissions_policy_allow', value => $_[0] } ) }

subtest 'config-read surfaces it' => sub {
    my $r = call('config-read');
    ok( $r->{ok} && exists $r->{config}{permissions_policy_allow}, 'config-read has permissions_policy_allow' );
};

subtest 'a list of askable features is stored, tidied' => sub {
    my $r = set('Camera geolocation, camera');
    ok( $r->{ok}, 'stored' ) or diag explain $r;
    like( conf(), qr/^permissions_policy_allow: camera, geolocation$/m, '...lower case, comma separated, each once' );
    is( call('config-read')->{config}{permissions_policy_allow}, 'camera, geolocation', 'config-read says so' );
    ok( set('none')->{ok}, 'none is accepted' );
    like( conf(), qr/^permissions_policy_allow: none$/m, '...and stored' );
};

subtest 'payment, browsing-topics and unknown names are refused, by name' => sub {
    ok( set('camera')->{ok}, 'a value to keep' );
    for my $case ( [ 'payment', qr/'payment' cannot be listed: payment: is the paid-page key/ ],
        [ 'camera, browsing-topics', qr/'browsing-topics' cannot be listed: .*no trackers/ ],
        [ 'fullscreen', qr/'fullscreen' is not a browser feature a page can ask for/ ],
        [ 'geolocaton', qr/'geolocaton' is not/ ] )
    {
        my ( $v, $re ) = @$case;
        my $r = set($v);
        ok( !$r->{ok}, "refused: '$v'" );
        is( $r->{field}, 'permissions_policy_allow', '...naming the field' );
        like( $r->{error} // '', $re, '...and the entry' );
        like( $r->{error} // '', qr/accelerometer, camera, .* or none/, '...with what can be listed' );
    }
    like( conf(), qr/^permissions_policy_allow: camera$/m, 'and the stored value is what it was' );
};

subtest 'empty clears it: no ceiling' => sub {
    my $r = set('');
    ok( $r->{ok}, 'cleared' ) or diag explain $r;
    unlike( conf(), qr/^permissions_policy_allow:[ \t]*\S/m, 'no list is left' );
};

subtest 'the Config page offers it' => sub {
    open my $fh, '<', "$root/starter/manager/config.md" or die $!;
    my $page = do { local $/; <$fh> };
    like( $page, qr/\{ key: 'permissions_policy_allow',[^}]*type: 'text'/s, 'a text field in SITE_SCHEMA' );
};

done_testing;
