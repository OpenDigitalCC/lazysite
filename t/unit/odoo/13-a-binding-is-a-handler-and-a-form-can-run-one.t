#!/usr/bin/perl
# SM747 CU: an Odoo binding is a handler of type `odoo`, made and checked where
# every destination is. A binding that cannot work is refused when it is SAVED,
# against the operation's own declaration (SM807) - unless OOM or the connection
# is not there to ask, when it is saved unvalidated and the call checks again.
#
# A form runs one as PUBLIC and the timer as SCHEDULED, as they run a
# connector; neither has a visitor key or anybody to confirm, so a binding
# needing either is refused there by name.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use OdooTest   qw(oom_or_skip shop_ready quiet);

BEGIN { oom_or_skip() }
use Lazysite::Handlers ();
use Lazysite::Odoo     ();

my ( $d, $fake ) = shop_ready();
$Lazysite::Handlers::DOCROOT = $d;

sub save {
    my (%h) = @_;
    my ( undef, $r ) = quiet( sub {
            Lazysite::Handlers::action_handler_save( { type => 'odoo', name => $h{id}, %h },
                caps => { manage_connectors => 1 } );
    } );
    return $r;
}

subtest 'saving checks the binding against its operation' => sub {
    ok( save( id => 'ok', operation => 'shop.products', modes => 'public' )->{ok}, 'a sound binding saves' );
    my $r = save( id => 'b1', operation => 'shop.nothing' );
    like( $r->{error}, qr/no operation 'shop\.nothing' is installed/, 'an operation that is not installed' );
    $r = save( id => 'b2', operation => 'shop.add', params => 'f=filter, p=product', visitor_param => 'basket_key' );
    like( $r->{error}, qr/'filter' is json/, 'a json parameter fed from a request' );
    $r = save( id => 'b3', operation => 'shop.add', params => 'p=product', modes => 'scheduled',
        fixed => 'basket_key=k' );
    like( $r->{error}, qr/nobody to confirm/, 'a scheduled write that waits for a confirm' );
    $r = save( id => 'b4', operation => 'shop.add', modes => 'nobody' );
    like( $r->{error}, qr/modes: 'nobody'/, 'the shape, before the operation is asked' );
    is( $r->{field}, 'modes', 'with the field it is about' );
};

subtest 'it needs the destination\'s capability' => sub {
    my ( undef, $r ) = quiet( sub {
            Lazysite::Handlers::action_handler_save(
                { type => 'odoo', id => 'x', name => 'x', operation => 'shop.products' },
                caps => { manage_forms => 1 } );
    } );
    is( $r->{kind}, 'forbidden', 'manage_forms is not enough' );
    like( $r->{error}, qr/manage_connectors/, 'it names the capability' );
};

subtest 'unvalidated is not invalid' => sub {
    my $bare = site_tempdir();
    local $Lazysite::Handlers::DOCROOT = $bare;
    my ( undef, $r ) = quiet( sub {
            Lazysite::Handlers::action_handler_save(
                { type => 'odoo', id => 'later', name => 'later', operation => 'shop.whatever' },
                unconstrained => 1 );
    } );
    ok( $r->{ok}, 'with no connection configured the binding saves' ) or diag explain $r;
};

subtest 'a form and the timer run a binding' => sub {
    save( id => 'signup', operation => 'shop.add', modes => 'public', apply => 'immediate',
        params => 'product=product', fixed => 'basket_key=newsletter' );
    my ( undef, $r ) = quiet( sub {
            Lazysite::Handlers::deliver( 'signup', { product => 2, email => 'x@example.org' },
                origin => 'form', source => 'form:shop', ip => '192.0.2.8' );
    } );
    ok( $r->{ok}, 'a public form applies it' ) or diag explain $r;
    is( $fake->record( 'x.basket', $fake->all_ids('x.basket')->[0] )->{basket_key}, 'newsletter',
        'with the fixed value' );

    save( id => 'staff-only', operation => 'shop.products', modes => 'authenticated', callers => 'staff' );
    ( undef, $r ) = quiet( sub {
            Lazysite::Handlers::deliver( 'staff-only', {}, origin => 'form', source => 'form:x' );
    } );
    ok( !$r->{ok}, 'a form cannot run an authenticated-only binding' );
    like( $r->{why}, qr/does not permit public/, 'the mode gate says so' );

    save( id => 'nightly', operation => 'shop.products', modes => 'scheduled' );
    ( undef, $r ) = quiet( sub {
            Lazysite::Handlers::deliver( 'nightly', {}, origin => 'timer', source => 'timer:n', actor => 'job' );
    } );
    ok( $r->{ok}, 'the timer runs a scheduled one' ) or diag explain $r;
};

subtest 'a form has no visitor and nobody to confirm' => sub {
    save( id => 'basket-form', operation => 'shop.add', modes => 'public', apply => 'immediate',
        params => 'product=product', visitor_param => 'basket_key' );
    my ( undef, $r ) = quiet( sub {
            Lazysite::Handlers::deliver( 'basket-form', { product => 1 }, origin => 'form', source => 'form:x' );
    } );
    like( $r->{why}, qr/only the Odoo page endpoint carries/, 'a visitor binding belongs on a page' );

    save( id => 'later-form', operation => 'shop.add', modes => 'public',
        params => 'product=product', fixed => 'basket_key=k' );
    ( undef, $r ) = quiet( sub {
            Lazysite::Handlers::deliver( 'later-form', { product => 1 }, origin => 'form', source => 'form:x' );
    } );
    like( $r->{why}, qr/nobody to give one/, 'a write waiting for a confirm is refused, not planned into a void' );
};

done_testing();
