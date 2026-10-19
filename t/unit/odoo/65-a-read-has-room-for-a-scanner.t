#!/usr/bin/perl
# SM1173 (OOM Lab L-14, ruled 2026-10-18): THE DEFAULT CAP DEPENDS ON WHAT THE
# BINDING DOES. "20 per caller per hour, 200 per binding stop a scanning app
# within minutes - the twentieth scan of a picking hit it, and the shared header
# read on every page blocked a session." Reads default to 2,000 per caller per
# hour and 20,000 per binding; writes keep 20 and 200; a binding's own number
# still wins, above or below, for either kind. The counter is driven directly
# (the rolling record the cap counts from), not by making 2,000 calls.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip shop_ready bind quiet);

BEGIN { oom_or_skip() }
use Lazysite::Odoo          ();
use Lazysite::Odoo::Binding ();
use Lazysite::Handlers      ();
use Lazysite::Odoo::Visitor ();

my ( $d, $fake ) = shop_ready();
$Lazysite::Odoo::Visitor::DOCROOT = $d;
my $KEY = ( Lazysite::Odoo::Visitor::mint() )[0];
my $rec = "$d/lazysite/odoo/recent.jsonl";

bind( $d, id => 'look',  operation => 'shop.products', modes => 'public' );
bind( $d, id => 'add',   operation => 'shop.add',      modes => 'public', apply => 'immediate', params => 'product=product', visitor_param => 'basket_key' );
bind( $d, id => 'look3', operation => 'shop.products', modes => 'public', rate_per_visitor_hour => 3, rate_per_hour => 5 );
bind( $d, id => 'add500', operation => 'shop.add', modes => 'public', apply => 'immediate',
    params => 'product=product', visitor_param => 'basket_key', rate_per_visitor_hour => 500, rate_per_hour => 5000 );

sub run {
    my ($id) = @_;
    my ( undef, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding($id);
            Lazysite::Odoo::call( $b, ( $id =~ /\Aadd/ ? { product => 1 } : {} ), mode => 'public', visitor_key => $KEY, strict => 1 );
    } );
    return $r;
}

# The caller's own label, as the engine writes it: one call, read back.
sub who_of {
    my ($id) = @_;
    unlink $rec;
    run($id);
    open my $fh, '<', $rec or die "no record: $!";
    my $l = <$fh>;
    close $fh;
    unlink $rec;
    return decode_json($l)->{who};
}

# $n stamps of $who on $id, within the hour.
sub seed {
    my ( $id, $n, $who ) = @_;
    open my $fh, '>>', $rec or die $!;
    my $now = time;
    print {$fh} encode_json( { at => $now, binding => $id, who => ref $who ? $who->() : $who } ), "\n" for 1 .. $n;
    close $fh;
}

sub fresh { unlink $rec }

my $who = who_of('look');
ok( length $who, 'the caller has a label' );

subtest 'a read has room for a scanner (per caller)' => sub {
    fresh();
    seed( 'look', 20, $who );
    my $r = run('look');
    ok( $r->{ok}, 'the 21st read in the hour is allowed' ) or diag $r->{error};
    fresh();
    seed( 'look', 1999, $who );
    ok( run('look')->{ok}, 'the 2,000th is allowed' );
    $r = run('look');
    is( $r->{kind}, 'rate', 'the 2,001st is refused' );
    like( $r->{error}, qr/per-\w+ cap: 2000 already in this hour and the cap is 2000/, 'by a cap of 2,000' );
};

subtest 'a read has room across the binding' => sub {
    fresh();
    my $i = 0;
    my $each = sub { 'caller-' . ( $i++ % 20 ) };    # 20 callers, 1,000 each: none near their own cap
    seed( 'look', 19_999, $each );
    ok( run('look')->{ok}, 'the 20,000th read of the binding is allowed' );
    my $r = run('look');
    is( $r->{kind}, 'rate', 'the next is refused' );
    like( $r->{error}, qr/per-binding cap: 20000 already in this hour and the cap is 20000/, 'by the binding cap of 20,000' );
};

subtest 'a write keeps 20 and 200' => sub {
    my $wwho = who_of('add');
    fresh();
    seed( 'add', 19, $wwho );
    ok( run('add')->{ok}, 'the 20th write is allowed' );
    my $r = run('add');
    is( $r->{kind}, 'rate', 'the 21st write is refused' );
    like( $r->{error}, qr/cap is 20\b/, 'by the cap of 20' );
    fresh();
    my $i = 0;
    seed( 'add', 200, sub { 'w-' . ( $i++ % 20 ) } );
    $r = run('add');
    is( $r->{kind}, 'rate', 'and 200 across the binding refuse a different caller' );
    like( $r->{error}, qr/per-binding cap: 200 already in this hour and the cap is 200/, 'by the binding cap of 200' );
};

subtest 'a binding\'s own cap wins, for a read and for a write' => sub {
    my $w3 = who_of('look3');
    fresh();
    seed( 'look3', 3, $w3 );
    my $r = run('look3');
    is( $r->{kind}, 'rate', 'a read binding set to 3 refuses the 4th, below the read default' );
    my $w5 = who_of('add500');
    fresh();
    seed( 'add500', 100, $w5 );
    ok( run('add500')->{ok}, 'a write binding set to 500 allows the 101st, above the write default' );
    fresh();
    seed( 'add500', 500, $w5 );
    is( run('add500')->{kind}, 'rate', 'and refuses at its own 500' );
};

subtest 'the manager form does not store the default for the operator' => sub {
    # A schema default is saved into the binding, which would pin every read
    # binding to the write numbers. Left empty, the binding stores nothing.
    no warnings 'once';
    local $Lazysite::Handlers::DOCROOT = $d;
    my $h = Lazysite::Handlers::find_handler( Lazysite::Handlers::read_handlers(), 'look' );
    ok( $h, 'the saved read binding is found' );
    ok( !exists $h->{rate_per_hour} && !exists $h->{rate_per_visitor_hour}, 'it stores no cap of its own' )
        or diag join ',', sort keys %$h;
};

done_testing();
