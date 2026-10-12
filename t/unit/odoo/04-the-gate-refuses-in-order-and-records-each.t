#!/usr/bin/perl
# SM747 / X4: the Odoo binding sits INSIDE SM579's policy. Who may cause a call
# is decided first, by Lazysite::Egress, exactly as a connector decides it -
# then whether the extension is on, then whether OOM is here and new enough,
# then the connection. Each refusal is a row in the call record (SM771: a
# refusal an operator cannot see is one they cannot manage).
#
# The order is tested by making EVERY later check fail at once: the refusal a
# caller gets is the first one, so a public visitor on an authenticated binding
# learns that the binding is not public - not which OOM version is installed.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper     qw(site_tempdir);
use OdooTest       qw(oom_lib pretend_released enable_odoo write_conf);
use Lazysite::Odoo ();

my $d = site_tempdir();
local $Lazysite::Odoo::DOCROOT = $d;
my $log = '';
open my $null, '>', \$log or die $!;
local *STDERR = $null;

my $binding = { id => 'staff-leads', operation => 'x.list',
    modes => { authenticated => 1, public => 0, scheduled => 0 }, callers => ['staff'] };

sub kinds {
    open my $fh, '<', Lazysite::Odoo::calls_file() or return [];
    my @k = map { decode_json($_)->{kind} } <$fh>;
    close $fh;
    return \@k;
}

subtest 'the mode is refused first, with everything else wrong too' => sub {
    my ( $ok, $r ) = Lazysite::Odoo::gate( $binding, mode => 'public', ip => '192.0.2.1' );
    ok( !$ok, 'refused' );
    is( $r->{kind}, 'mode', 'by mode, not by the missing extension or OOM' );
    like( $r->{error}, qr/does not permit public invocation/, 'in Egress\'s words' );
    like( $r->{error}, qr/permits: authenticated/, 'naming what would work (SM807)' );

    ( $ok, $r ) = Lazysite::Odoo::gate( $binding, mode => 'authenticated', groups => ['other'], caps => {} );
    is( $r->{kind}, 'mode', 'an account outside the callers is refused by the same gate' );
    like( $r->{error}, qr/none of the groups/, 'and told so' );

    ( $ok, $r ) = Lazysite::Odoo::gate( $binding, mode => 'proxy' );
    like( $r->{error}, qr/not one of scheduled, authenticated, public/, 'a mode outside the three is refused' );
};

subtest 'then the extension switch' => sub {
    my ( $ok, $r ) = Lazysite::Odoo::gate( $binding, mode => 'authenticated', groups => ['staff'] );
    is( $r->{kind}, 'disabled', 'a permitted caller meets the off switch' );
    ( $ok, $r ) = Lazysite::Odoo::gate( $binding, mode => 'authenticated', groups => [],
        caps => { manage_connectors => 1 } );
    is( $r->{kind}, 'disabled', 'the override capability passes the mode gate, not the switch' );
};

enable_odoo($d);

subtest 'then OOM: absent, and too old, each by name' => sub {
    plan skip_all => 'an Odoo::Ops is already installed on this host'
        if eval { require Odoo::Ops; 1 };
    my ( $ok, $r ) = Lazysite::Odoo::gate( $binding, mode => 'authenticated', groups => ['staff'] );
    is( $r->{kind}, 'unavailable', 'kind unavailable' );
    like( $r->{error}, qr/needs libodoo-oom-perl \(>= 0\.02\) - it is not installed/,
        'the package and version are named' );

    plan skip_all => 'no OOM tree to test the version against' unless -f oom_lib() . '/Odoo/Ops.pm';
    unshift @INC, oom_lib();
    ( $ok, $r ) = Lazysite::Odoo::gate( $binding, mode => 'authenticated', groups => ['staff'] );
    is( $r->{kind}, 'unavailable', 'the 0.01 tree is refused too' );
    like( $r->{error}, qr/this host has 0\.01/, 'saying which version is here' );
};

subtest 'then the connection, and then through' => sub {
    plan skip_all => 'no OOM tree' unless -f oom_lib() . '/Odoo/Ops.pm';
    unshift @INC, oom_lib() unless grep { $_ eq oom_lib() } @INC;
    pretend_released();
    my ( $ok, $r ) = Lazysite::Odoo::gate( $binding, mode => 'authenticated', groups => ['staff'] );
    is( $r->{kind}, 'config', 'an unconfigured connection is the next refusal' );

    write_conf( $d, odoo_url => 'http://10.0.0.8', odoo_db => 'db', odoo_login => 'c' );
    ( $ok, $r ) = Lazysite::Odoo::gate( $binding, mode => 'authenticated', groups => ['staff'] );
    like( $r->{error}, qr/X4-a/, 'X4-a holds at the gate, not only at save' );

    write_conf( $d, odoo_url => 'https://odoo.example', odoo_db => 'db', odoo_login => 'c' );
    ( $ok, $r ) = Lazysite::Odoo::gate( $binding, mode => 'authenticated', groups => ['staff'] );
    ok( $ok, 'a permitted caller on a configured site passes' );
    is( $r->{login}, 'c', 'and is handed the connection' );
};

my $k = kinds();
ok( scalar( grep { $_ eq 'mode' } @$k ) >= 3,     'every mode refusal is a row' );
ok( scalar( grep { $_ eq 'disabled' } @$k ) >= 2, 'so is every switch refusal' );
ok( ( grep { $_ eq 'config' } @$k ),              'and the config refusal' );

done_testing();
