#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);
load_processor($docroot);

# --- no payment required passes ---
{
    my $r = main::check_payment( '/page', {}, { ok => 1 }, {} );
    is( $r->{ok}, 1, 'no payment_required → ok' );
}

# --- payment required without proof → payment_required ---
{
    delete $ENV{HTTP_X_PAYMENT_VERIFIED};
    my $r = main::check_payment(
        '/page',
        {
            payment          => 'required',
            payment_amount   => '0.01',
            payment_currency => 'USD',
            payment_address  => '0xABC',
        },
        { ok => 1, authenticated => 0, auth_groups => [] },
        {},
    );
    is( $r->{payment_required}, 1,       'payment_required flag set' );
    is( $r->{amount},           '0.01',  'amount echoed' );
    is( $r->{currency},         'USD',   'currency echoed' );
    is( $r->{address},          '0xABC', 'address echoed' );
}

# --- payment proof grants access ---
{
    local $ENV{HTTP_X_PAYMENT_VERIFIED} = '1';
    my $r = main::check_payment(
        '/page', { payment => 'required' },
        { ok => 1, authenticated => 0, auth_groups => [] }, {},
    );
    is( $r->{ok},   1, 'payment proof → ok' );
    is( $r->{paid}, 1, 'paid flag set' );
}

# --- group member bypasses payment ---
{
    delete $ENV{HTTP_X_PAYMENT_VERIFIED};
    my $r = main::check_payment(
        '/page',
        { payment => 'required', auth_groups => ['members'] },
        {
            ok            => 1,
            authenticated => 1,
            auth_groups   => [ 'members', 'admins' ],
        },
        {},
    );
    is( $r->{ok},       1, 'group member bypass → ok' );
    is( $r->{bypassed}, 1, 'bypassed flag set' );
}

# --- authenticated but wrong group still pays ---
{
    my $r = main::check_payment(
        '/page',
        { payment => 'required', auth_groups => ['admins'] },
        { ok => 1, authenticated => 1, auth_groups => ['members'] },
        {},
    );
    is( $r->{payment_required}, 1, 'wrong group still requires payment' );
}

# --- no auth_groups set: all authed users still pay ---
{
    my $r = main::check_payment(
        '/page',
        { payment => 'required' },
        { ok => 1, authenticated => 1, auth_groups => ['admins'] },
        {},
    );
    is( $r->{payment_required}, 1,
        'no bypass auth_groups → everyone pays' );
}

done_testing();
