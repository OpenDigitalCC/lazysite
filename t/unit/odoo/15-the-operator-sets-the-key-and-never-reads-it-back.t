#!/usr/bin/perl
# SM747 CU / OB1 (amended R1): the operator's actions on the connection user.
# The key is SET and CLEARED and never read back: odoo-status answers
# has_secret - 1, 0, or null for "cannot tell" - and the connection without its
# key. All four actions are manage_connectors' (until slice E's manage_odoo),
# and the two that change the key are POST-only on both channels.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip shop_ready bind quiet);

BEGIN { oom_or_skip() }
use Lazysite::Odoo                ();
use Lazysite::ControlApi::Actions ();

my ( $d, $fake ) = shop_ready( no_key => 1 );
my $KEY = 'Op3rator-set-key-9';

sub status { return ( quiet( sub { Lazysite::Odoo::action_odoo_status() } ) )[1] }

my $s = status();
is( $s->{has_secret},        0,                 'no key yet: has_secret 0' );
is( $s->{connection}{login}, 'site-connection', 'the connection is described' );
ok( $s->{enabled}, 'and the extension is on' );
ok( ( grep { $_->{name} eq 'shop.add' && $_->{writes} } @{ $s->{operations} || [] } ),
    'the installed operations are listed, writes marked' );

my ( undef, $r ) = quiet( sub { Lazysite::Odoo::action_odoo_secret_set($KEY) } );
ok( $r->{ok}, 'the key is set' );
unlike( encode_json($r), qr/\Q$KEY\E/, 'and the answer does not carry it' );
$s = status();
is( $s->{has_secret}, 1, 'has_secret 1' );
unlike( encode_json($s), qr/\Q$KEY\E/, 'the status never carries the key' );

( undef, $r ) = quiet( sub { Lazysite::Odoo::action_odoo_secret_set("two\nlines") } );
ok( !$r->{ok}, 'a bad key is refused' );
is( $r->{field},            'secret', 'naming the field' );
is( status()->{has_secret}, 1,        'and the good one stands' );

SKIP: {
    skip 'root reads anything', 2 if $> == 0;
    chmod 0000, "$d/lazysite/odoo/keys/connection.key";
    $s = status();
    chmod 0600, "$d/lazysite/odoo/keys/connection.key";
    is( $s->{has_secret}, undef, 'a key that cannot be read: null, not 0' );
    like( $s->{warning}, qr/cannot be read/, 'with a warning' );
}

( undef, $r ) = quiet( sub { Lazysite::Odoo::action_odoo_secret_clear() } );
ok( $r->{ok}, 'cleared' );
is( status()->{has_secret}, 0, 'has_secret 0 again' );

bind( $d, id => 'list', operation => 'shop.products', modes => 'public' );
quiet( sub { my ($b) = Lazysite::Odoo::find_binding('list'); Lazysite::Odoo::call( $b, {}, mode => 'public' ) } );
my ( undef, $calls ) = quiet( sub { Lazysite::Odoo::action_odoo_calls( binding => 'list' ) } );
is( $calls->{calls}[0]{kind}, 'no-key', 'the call record shows the refusal for the missing key' );

my $A = \%Lazysite::ControlApi::Actions::ACTION;
for my $a (qw(odoo-status odoo-secret-set odoo-secret-clear odoo-calls)) {
    is_deeply( $A->{$a}{caps}, ['manage_connectors'], "$a is manage_connectors'" );
}
my %mut = Lazysite::ControlApi::Actions::mutating();
ok( $mut{'odoo-secret-set'} && $mut{'odoo-secret-clear'}, 'setting and clearing are POST-only' );
ok( !$mut{'odoo-status'},                                 'the status is a read' );

done_testing();
