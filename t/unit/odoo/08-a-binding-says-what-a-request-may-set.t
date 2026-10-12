#!/usr/bin/perl
# SM747 CU / Q1: PARAMETER INJECTION. A binding decides what a request may set,
# and the answer is: only the fields it maps, only into plain-value parameters,
# never over a fixed one, never the visitor's key. A json parameter is a
# domain, a list a set of ids, a path a file on this server - a request can
# feed none of them, whatever the operator maps. The operation's own
# declaration (OOM's `params`) is what each value is checked against.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip);

BEGIN { oom_or_skip() }
use LazysiteTest::OdooOps::Add;
use Lazysite::Odoo::Binding ();

my $ADD = 'LazysiteTest::OdooOps::Add';
sub parse { return Lazysite::Odoo::Binding::parse( { id => 'b', operation => 'shop.add', @_ } ) }

subtest 'the shape' => sub {
    my ( $b, $why ) = parse( params => 'product=product, qty=qty', visitor_param => 'basket_key',
        modes => 'public' );
    ok( $b, 'a basket binding parses' ) or diag $why;
    is_deeply( $b->{modes}, { public => 1, authenticated => 0, scheduled => 0 }, 'modes are three booleans' );
    is( $b->{apply},                 'confirm', 'apply defaults to confirm' );
    is( $b->{rate_per_visitor_hour}, 20,        'per-visitor cap defaults' );
    is( $b->{rate_per_hour},         200,       'per-binding cap defaults' );

    my %bad = (
        'operation is required'         => [ operation => '' ],
        'is not an operation name'      => [ operation => 'Shop/Add' ],
        'each parameter has one source' => [ params => 'p=product', fixed => 'product=3' ],
        'set by params and visitor_param' => [ params => 'k=basket_key', visitor_param => 'basket_key' ],
        "modes: 'everyone'"                  => [ modes => 'everyone' ],
        'apply must be confirm or immediate' => [ apply => 'later' ],
        'cannot be scheduled' => [ visitor_param => 'basket_key', modes => 'scheduled' ],
        "'p=' is not name=value"        => [ params        => 'p=' ],
        'is named twice'                => [ params        => 'a=product, a=qty' ],
        'rate_per_hour must be a whole' => [ rate_per_hour => 'lots' ],
    );
    for my $want ( sort keys %bad ) {
        my ( $x, $w ) = parse( @{ $bad{$want} } );
        ok( !$x, "refused: $want" );
        like( $w // '', qr/\Q$want\E/, 'and says so' );
    }
};

subtest 'against the operation\'s declaration' => sub {
    my %bad = (
        "parameter 'nope' is not one shop.add declares" => [ params => 'x=nope' ],
        "'filter' is json - a request may feed only a plain value" => [ params => 'f=filter' ],
        "'journal' names a file on this server" => [ fixed => 'journal=/etc/passwd' ],
        "requires 'product' and the binding gives it no source" =>
            [ params => 'q=qty', visitor_param => 'basket_key' ],
        'a scheduled run has nobody to confirm' => [ params => 'p=product', fixed => 'basket_key=k', modes => 'scheduled' ],
    );
    for my $want ( sort keys %bad ) {
        my ($b) = parse( @{ $bad{$want} } );
        like( Lazysite::Odoo::Binding::check_against( $b, $ADD ), qr/\Q$want\E/, "refused: $want" );
    }
    my ($ok) = parse( params => 'p=product', fixed => 'filter=[]', visitor_param => 'basket_key' );
    is( Lazysite::Odoo::Binding::check_against( $ok, $ADD ), '', 'a json parameter may be FIXED by the operator' );
};

subtest 'what a request carries' => sub {
    my ($b) = parse( params => 'product=product, qty=qty', visitor_param => 'basket_key',
        fixed => 'filter=[]' );
    my %v = ( visitor => 'K' x 64 );

    my ( $p, $why ) = Lazysite::Odoo::Binding::assemble( $b, $ADD, { product => '3', qty => '2' }, %v, strict => 1 );
    is_deeply( $p, { product => 3, qty => 2, filter => '[]', basket_key => 'K' x 64 },
        'mapped fields, the fixed value and the server\'s key' ) or diag $why;

    ( $p, $why ) = Lazysite::Odoo::Binding::assemble( $b, $ADD,
        { product => 3, basket_key => 'someone-elses' }, %v, strict => 1 );
    ok( !$p, 'a request naming the visitor parameter is refused at the endpoint' );
    like( $why, qr/does not take: basket_key/, 'by name' );

    ( $p, $why ) = Lazysite::Odoo::Binding::assemble( $b, $ADD,
        { product => 3, basket_key => 'someone-elses', filter => '[["id",">",0]]' }, %v );
    is( $p->{basket_key}, 'K' x 64, 'from a form it is dropped, and the server\'s key stands' );
    is( $p->{filter}, '[]',         'and the fixed value cannot be overridden' );

    for my $case (
        [ { product => 'three' },              qr/must be a whole number/ ],
        [ { product => [3] },                  qr/single value/ ],
        [ { product => "3\x00" },              qr/control character/ ],
        [ { product => 3, qty => 'x' x 1001 }, qr/longer than 1000/ ],
        [ { qty     => 2 },                    qr/'product' is required/ ],
        )
    {
        my ( $x, $w ) = Lazysite::Odoo::Binding::assemble( $b, $ADD, $case->[0], %v );
        ok( !$x, 'refused' );
        like( $w, $case->[1], "says $case->[1]" );
    }

    ( $p, $why ) = Lazysite::Odoo::Binding::assemble( $b, $ADD, { product => 3 } );
    ok( !$p, 'a visitor binding with no visitor key is refused' );
    like( $why, qr/carries no visitor key/, 'and says what is missing' );
};

done_testing();
