#!/usr/bin/perl
# SM1165 (OOM Lab L-10, lazysite-sites agent): "A write with `apply: immediate`
# answers counts and buckets but not WHAT it made: the page cannot learn the
# new record's id." OOM's result carries `created` and `written` (model to ids,
# this plan's own changes); the apply answer passes both on, for an immediate
# binding and for a confirmed plan alike. `unlinked` and the journal's path
# stay out.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip shop_ready bind quiet);

BEGIN { oom_or_skip() }
use Lazysite::Odoo ();

my ( $d, $fake ) = shop_ready();
bind( $d, id => 'order', operation => 'shop.add', modes => 'authenticated', callers => 'staff',
    params => 'product=product', fixed => 'basket_key=counter' );
bind( $d, id => 'quick', operation => 'shop.add', modes => 'public', apply => 'immediate',
    params => 'product=product', fixed => 'basket_key=quick' );

my %SAM = ( user => 'sam', groups => ['staff'], caps => {}, ip => '192.0.2.5', channel => 'api' );

sub act { my ( $name, @a ) = @_; return ( quiet( sub { Lazysite::Odoo->can($name)->(@a) } ) )[1] }

sub quick {
    my ($product) = @_;
    my ( undef, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding('quick');
            Lazysite::Odoo::call( $b, { product => $product }, mode => 'public', visitor_key => undef,
                ip => '192.0.2.9' );
    } );
    return $r;
}

subtest 'an immediate create answers the id it made' => sub {
    my $r = quick(1);
    ok( $r->{applied}, 'applied' ) or diag explain $r;
    my $ids = $fake->all_ids('x.basket');
    is( scalar @$ids, 1, 'one record in Odoo' );
    is_deeply( $r->{result}{created}, { 'x.basket' => [ $ids->[0] ] }, 'created: model to the new id' );
    is_deeply( $r->{result}{written}, {}, 'nothing was written' );
};

subtest 'an immediate write answers the id it changed' => sub {
    my $r = quick(1);
    ok( $r->{applied}, 'applied' ) or diag explain $r;
    my $ids = $fake->all_ids('x.basket');
    is_deeply( $r->{result}{written}, { 'x.basket' => [ $ids->[0] ] }, 'written: model to the id' );
    is_deeply( $r->{result}{created}, {}, 'nothing was created' );
};

subtest 'a confirmed plan answers the same, and passes on nothing else of the runner' => sub {
    my $before = $fake->all_ids('x.basket');
    my $p = act( 'action_odoo_run', 'order', { product => 2 }, %SAM );
    ok( $p->{planned}, 'a plan' ) or diag explain $p;
    my $c = act( 'action_odoo_confirm', $p->{plan}, %SAM );
    ok( $c->{applied}, 'confirmed: applied' ) or diag explain $c;
    my %was = map { $_ => 1 } @$before;
    my @new = grep { !$was{$_} } @{ $fake->all_ids('x.basket') };
    is( scalar @new, 1, 'one new record' );
    is_deeply( $c->{result}{created}, { 'x.basket' => [ $new[0] ] }, 'created: the same shape' );
    ok( !exists $c->{result}{unlinked}, 'unlinked stays out' );
    ok( !exists $c->{result}{journal},  'the journal stays out' );
    my @keys = sort keys %{ $c->{result} };
    my @bad  = grep { !/^(?:total|counts|by_bucket|verified|stopped_by|created|written)$/ } @keys;
    is_deeply( \@bad, [], 'only the named fields are passed' ) or diag "@keys";
};

done_testing;
