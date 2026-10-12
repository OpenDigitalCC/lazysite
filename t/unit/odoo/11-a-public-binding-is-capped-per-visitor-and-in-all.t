#!/usr/bin/perl
# SM747 CU / Q1: BASKET FLOODING AND QUOTATION SPAM. An anonymous write path
# needs a ceiling a script cannot talk its way past: per visitor per hour, and
# per binding per hour across every visitor (a script can mint visitors). The
# slot is taken BEFORE the call, so an attempt Odoo refuses still counts, and a
# record that cannot be read refuses rather than reading as zero.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip shop_ready bind quiet fake_shop);

BEGIN { oom_or_skip() }
use Odoo::Error;
use Lazysite::Odoo          ();
use Lazysite::Odoo::Visitor ();

my ( $d, $fake ) = shop_ready();
$Lazysite::Odoo::Visitor::DOCROOT = $d;
bind( $d, id => 'add', operation => 'shop.add', modes => 'public', apply => 'immediate',
    params                => 'product=product', visitor_param => 'basket_key',
    rate_per_visitor_hour => 2,                 rate_per_hour => 3 );

my @v = map { ( Lazysite::Odoo::Visitor::mint() )[0] } 1 .. 3;

sub add {
    my ($key) = @_;
    my ( undef, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding('add');
            Lazysite::Odoo::call( $b, { product => 1 }, mode => 'public', visitor_key => $key, strict => 1 );
    } );
    return $r;
}

ok( add( $v[0] )->{ok}, 'visitor 1, first add' );
ok( add( $v[0] )->{ok}, 'visitor 1, second add' );
my $r = add( $v[0] );
is( $r->{kind}, 'rate', 'visitor 1, third add: refused' );
like( $r->{error}, qr/per-visitor cap: 2 already in this hour/, 'by the per-visitor cap, said in Egress\'s words' );
like( $r->{error}, qr/raise rate_per_visitor_hour on the binding 'add'/, 'naming the setting' );

ok( add( $v[1] )->{ok}, 'visitor 2, first add - the binding\'s third' );
$r = add( $v[2] );
is( $r->{kind}, 'rate', 'visitor 3: refused though new' );
like( $r->{error}, qr/per-binding cap: 3/, 'by the per-binding cap - minting visitors does not get past it' );

subtest 'an attempt Odoo refuses still counts' => sub {
    unlink "$d/lazysite/odoo/recent.jsonl";
    $Lazysite::Odoo::TRANSPORT = fake_shop( fake => { fail => {
                'x.product.search_read' => Odoo::Error->new( kind => 'transport', message => 'down' ) } } );
    is( add( $v[0] )->{kind}, 'transport-failure', 'a failed attempt' );
    is( add( $v[0] )->{kind}, 'transport-failure', 'and another' );
    is( add( $v[0] )->{kind}, 'rate', 'the third is capped - failures spent the allowance' );
    $Lazysite::Odoo::TRANSPORT = $fake;
};

subtest 'the window rolls' => sub {
    open my $fh, '>', "$d/lazysite/odoo/recent.jsonl" or die $!;
    print {$fh} encode_json( { at => time - 3700, binding => 'add', who => 'x' } ), "\n" for 1 .. 5;
    close $fh;
    ok( add( $v[0] )->{ok}, 'stamps older than an hour are not counted' );
};

subtest 'a record that cannot be read refuses' => sub {
    plan skip_all => 'root reads anything' if $> == 0;
    chmod 0000, "$d/lazysite/odoo/recent.jsonl";
    my $r = add( $v[1] );
    chmod 0660, "$d/lazysite/odoo/recent.jsonl";
    is( $r->{kind}, 'rate', 'refused' );
    like( $r->{error}, qr/cannot tell how much/, 'as unknown, not as zero' );
};

done_testing();
