#!/usr/bin/perl
# SM747 R (R4, Q3): Odoo's field descriptors are drawn in the data extension's
# terms through the PORTABLE type OOM hands over, and a field without one - or
# with one the data extension does not know - is REFUSED by name. Lazysite never
# reads Odoo's own type, so it cannot guess; what it draws passes the data
# extension's own descriptor check, so an Odoo column is as well-formed as a
# site's.
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
use Lazysite::Odoo::Fields  ();

my ( $f, $refused ) = Lazysite::Odoo::Fields::descriptor_fields( {
        name => { type => 'char', string => 'Name', required => 1, portable_type => 'text' },
        qty => { type => 'integer', portable_type => 'integer' },
        state => { type => 'selection', portable_type => 'enum', values => [qw(draft sent)] },
        amount => { type => 'monetary', portable_type => 'decimal', digits => 12, places => 2 },
        id      => { type => 'integer',   portable_type => 'integer' },
        partner => { type => 'many2one',  relation      => 'x.partner' },
        body    => { type => 'html',      portable_type => 'html' },
        price   => { type => 'float',     portable_type => 'decimal' },
        level   => { type => 'selection', portable_type => 'enum' },
        Bad     => { portable_type => 'text' },
        tight   => { portable_type => 'decimal', digits => 2, places => 5 },
} );

subtest 'what has a portable type is drawn' => sub {
    is_deeply( $f->{name}, { type => 'text', title => 'Name', required => 'true' }, 'text, with its label' );
    is( $f->{qty}{type}, 'integer', 'integer' );
    is_deeply( $f->{state}{values}, [qw(draft sent)], 'an enum keeps its values' );
    is_deeply( [ @{ $f->{amount} }{qw(type digits places)} ], [ 'decimal', 12, 2 ], 'a decimal its precision' );
    ok( $f->{id}, 'a row\'s id is drawable' );
};

my %why = map { $_->{field} => $_->{why} } @$refused;
subtest 'what has not is refused by name, never guessed' => sub {
    like( $why{partner}, qr/no portable_type, and lazysite does not guess/, 'no portable type' );
    like( $why{body}, qr/'html' is not one of/, 'a type the data extension does not know' );
    like( $why{price}, qr/needs digits/,        'a decimal without its precision' );
    like( $why{level}, qr/needs its values/,    'an enum without its values' );
    like( $why{Bad},   qr/not a field name/,    'a name the data extension cannot hold' );
    like( $why{tight}, qr/cannot exceed/, "a field the data extension's own check refuses" );
    is( scalar @$refused, 6, 'and nothing else' );
    ok( !exists $f->{partner}, 'a refused field is not drawn half-way' );
};

subtest 'the parameter form is what a request may set' => sub {
    my ($b) = Lazysite::Odoo::Binding::parse( { id => 'b', operation => 'shop.add',
            params => 'product=product, how_many=qty', visitor_param => 'basket_key', fixed => 'filter=[]' } );
    my $form = Lazysite::Odoo::Fields::form_fields( $b, 'LazysiteTest::OdooOps::Add' );
    is_deeply( [ sort keys %$form ], [qw(how_many product)], 'the request\'s names, and only the mapped ones' );
    is( $form->{product}{type},      'integer', 'typed from the declaration' );
    is( $form->{product}{required},  'true', 'required where the operation requires it' );
    is( $form->{how_many}{required}, 'false', 'not where it has a default' );
    is( $form->{how_many}{default},  '1',     'which the form carries' );
    ok( !exists $form->{basket_key} && !exists $form->{filter},
        'no field for the visitor key or a fixed value' );
};

done_testing();
