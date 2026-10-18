#!/usr/bin/perl
# SM1166: A BINDING TAKES A DECLARED LIST OF ROWS. A request may feed a
# parameter the operation declares as OOM 0.32's `rows` type (a quotation's
# lines), and only that: the rows are checked by OOM's own check_rows AND by
# the plain-value rule every other request value passes, before anything
# reaches Odoo. A json, list or path parameter is still the operator's alone.
# A rows parameter with no cap, or whose row keys are unknowable until plan
# (core.make's lines.<field>), is not offered to a request.
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip shop_ready bind quiet);

BEGIN { oom_or_skip() }
use Lazysite::Odoo ();
use Lazysite::Odoo::Binding ();
use Lazysite::Handlers ();

my ( $d, $fake ) = shop_ready();

sub save {
    my (%h) = @_;
    no warnings 'once';
    local $Lazysite::Handlers::DOCROOT = $d;
    return Lazysite::Handlers::action_handler_save( { type => 'odoo', name => $h{id}, %h }, unconstrained => 1 );
}

bind( $d, id => 'order', operation => 'shop.order', modes => 'authenticated', callers => 'staff',
    apply => 'immediate', params => 'lines=lines', fixed => 'basket_key=cart' );
bind( $d, id => 'order2', operation => 'shop.order', modes => 'authenticated', callers => 'staff',
    apply => 'immediate', params => 'lines=lines', fixed => 'basket_key=cart', rows_max => 2 );

my %SAM = ( user => 'sam', groups => ['staff'], caps => {}, ip => '192.0.2.5', channel => 'api' );
sub run {
    my ( $id, $params ) = @_;
    return ( quiet( sub { Lazysite::Odoo::action_odoo_run( $id, $params, %SAM ) } ) )[1];
}
sub n_basket { return scalar @{ $fake->all_ids('x.basket') } }

subtest 'rows reach the operation as an array of hashes' => sub {
    my $r = run( 'order', { lines => [ { product_id => 1, qty => 2 }, { product_id => 2, qty => 1, note => 'hi', gift => JSON::PP::true } ] } );
    ok( $r->{applied}, 'applied' ) or diag explain $r;
    is( n_basket(), 2, 'one record per row reached Odoo' );
};

subtest 'a bad list is refused whole, naming the row and field, and Odoo is not called' => sub {
    my $row = sub { { product_id => 1, qty => 1, @_ } };
    my %bad = (
        'over max'            => [ [ $row->(), $row->(), $row->(), $row->() ], qr/4 rows; at most 3/ ],
        'undeclared key'      => [ [ $row->(), $row->( colour => 'red' ) ],   qr/row 2: key 'colour' is not declared/ ],
        'missing required'    => [ [ { product_id => 1 } ],                   qr/row 1: key 'qty' is required/ ],
        'wrong type'          => [ [ $row->(), $row->( qty => 'many' ) ],     qr/row 2: key 'qty' must be int/ ],
        'nesting'             => [ [ $row->( note => { a => 1 } ) ],          qr/row 1: key 'note'.*nested/ ],
        'row not an object'   => [ [ 'x' ],                                   qr/row 1 must be an object/ ],
        'control character'   => [ [ $row->(), $row->( note => "a\x01b" ) ],  qr/row 2.*'note'.*control character/ ],
        'over-long str'       => [ [ $row->( note => 'x' x 1001 ) ],          qr/row 1: 'note' is longer than 1000 characters/ ],
        'not a list'          => [ 'a,b',                                      qr/'lines' must be a list of rows/ ],
        'an object'           => [ { product_id => 1 },                        qr/'lines' must be a list of rows/ ],
    );
    my $before = n_basket();
    for my $name ( sort keys %bad ) {
        my $r = run( 'order', { lines => $bad{$name}[0] } );
        is( $r->{kind}, 'invalid', "$name: refused as invalid" ) or diag explain $r;
        like( $r->{error} // '', $bad{$name}[1], "$name: names where" );
    }
    is( n_basket(), $before, 'nothing reached Odoo' );
};

subtest 'a lower cap of the binding\'s own' => sub {
    my $row = { product_id => 1, qty => 1 };
    my $r = run( 'order2', { lines => [ $row, $row, $row ] } );
    is( $r->{kind}, 'invalid', 'three rows under a binding that allows two' );
    like( $r->{error} // '', qr/3 rows; at most 2/, 'and says the cap' );
    ok( run( 'order2', { lines => [ $row, $row ] } )->{applied}, 'two pass' );
    my $x = save( id => 'high', operation => 'shop.order', params => 'lines=lines', fixed => 'basket_key=c', rows_max => 9 );
    ok( $x->{ok}, 'a rows_max above the operation\'s own is harmless' ) or diag explain $x;
    $x = save( id => 'bad', operation => 'shop.order', params => 'lines=lines', fixed => 'basket_key=c', rows_max => 'many' );
    ok( !$x->{ok}, 'a rows_max that is not a whole number is refused' );
};

subtest 'the body\'s params must still be an object' => sub {
    my $r = run( 'order', [ { product_id => 1, qty => 1 } ] );
    is( $r->{kind}, 'invalid', 'params that are a list' );
    like( $r->{error}, qr/params must be an object/, 'by name' );
};

subtest 'a nested value is allowed only into a rows parameter' => sub {
    bind( $d, id => 'add', operation => 'shop.add', modes => 'authenticated', callers => 'staff',
        params => 'product=product', fixed => 'basket_key=cart' );
    my $r = run( 'add', { product => [ { a => 1 } ] } );
    is( $r->{kind}, 'invalid', 'an array into an int parameter' );
    like( $r->{error}, qr/single value/, 'is refused' );
};

subtest 'a rows parameter with no cap is refused when the binding is saved' => sub {
    my $r = save( id => 'nomax', operation => 'shop.nomax', modes => 'authenticated', params => 'lines=lines' );
    ok( !$r->{ok}, 'refused' );
    like( $r->{error} // '', qr/'lines'.*no max/, 'naming the parameter' );
    my ($b) = Lazysite::Odoo::Binding::parse( { id => 'n', operation => 'shop.nomax', params => 'lines=lines' } );
    like( Lazysite::Odoo::Binding::check_against( $b, 'LazysiteTest::OdooOps::Nomax' ), qr/'lines'.*no max/, 'and by the check itself' );
};

subtest 'a rows parameter whose row keys are unknowable is the operator\'s alone' => sub {
    my $r = save( id => 'dyn', operation => 'shop.dyn', modes => 'authenticated', params => 'lines=lines' );
    ok( !$r->{ok}, 'a request field mapped into it is refused' );
    like( $r->{error} // '', qr/'lines'.*row.*not.*known|'lines'.*operator/i, 'naming the parameter and why' );
    $r = save( id => 'dyn-fixed', operation => 'shop.dyn', modes => 'authenticated', fixed => 'lines=[]' );
    ok( $r->{ok}, 'the operator may fix it' ) or diag explain $r;
};

subtest 'json, list and path stay the operator\'s' => sub {
    my $r = save( id => 'j', operation => 'shop.add', params => 'f=filter,p=product', fixed => 'basket_key=c' );
    ok( !$r->{ok}, 'a request cannot feed a json parameter' );
    like( $r->{error} // '', qr/'filter' is json - a request may feed only a plain value/, 'as before' );
    like( $r->{error} // '', qr/\(str, int, bool\)|rows/, 'and the message now names rows' );
};

done_testing();
