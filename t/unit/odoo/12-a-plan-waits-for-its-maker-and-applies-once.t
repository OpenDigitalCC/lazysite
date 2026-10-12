#!/usr/bin/perl
# SM747 CU: a write operation's plan is shown as its buckets and applied when
# the account (or visitor) that made it confirms - once, against the binding as
# it stands NOW, refusing a plan that went stale, was edited, has expired, or
# whose binding was switched off. OOM's own refusals arrive as named kinds.
#
# REPLAY: confirming the same plan twice applies it once. The journal OOM writes
# beside the plan is what says it was applied, and the second confirm meets it.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip shop_ready bind quiet write_conf shop_namespace);

BEGIN { oom_or_skip() }
use Lazysite::Odoo ();

my ( $d, $fake ) = shop_ready( shop => { records => { 'x.basket' => [] } } );
bind( $d, id => 'staff-add', operation => 'shop.add', modes => 'authenticated', callers => 'staff',
    params => 'product=product', fixed => 'basket_key=counter' );

my %STAFF = ( mode => 'authenticated', actor => 'sam', groups => ['staff'] );

sub plan_one {
    my ( undef, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding('staff-add');
            Lazysite::Odoo::call( $b, { product => 1 }, %STAFF, strict => 1 );
    } );
    return $r;
}

sub confirm_as {
    my ( $pid,  %c ) = @_;
    my ( undef, $r ) = quiet( sub { Lazysite::Odoo::confirm( $pid, %c ) } );
    return $r;
}

sub baskets { return scalar @{ $fake->all_ids('x.basket') } }

subtest 'plan, preview, confirm, and once only' => sub {
    my $p = plan_one();
    ok( $p->{planned}, 'a plan, not a write' ) or diag explain $p;
    is( baskets(), 0, 'nothing written yet' );
    is_deeply( $p->{preview}{buckets}, { 'new-line' => 1 }, 'the preview is the buckets' );
    is( $p->{preview}{changes}[0]{action}, 'create', 'and what each change is' );

    my $other = confirm_as( $p->{plan}, %STAFF, actor => 'mo' );
    is( $other->{kind}, 'not-found', 'another account cannot confirm it' );

    my $c = confirm_as( $p->{plan}, %STAFF );
    ok( $c->{ok} && $c->{applied}, 'its maker confirms it' ) or diag explain $c;
    is( baskets(),              1, 'and it is written' );
    is( $c->{result}{verified}, 1, 'and read back' );

    my $again = confirm_as( $p->{plan}, %STAFF );
    is( $again->{kind}, 'applied', 'a second confirm is refused as already applied' );
    is( baskets(),      1,         'and writes nothing' );
};

subtest 'a stale plan is refused' => sub {
    my $p1 = plan_one();
    my $c1 = confirm_as( $p1->{plan}, %STAFF );    # line exists now; next plan writes it
    my $p  = plan_one();
    is_deeply( $p->{preview}{buckets}, { more => 1 }, 'a plan to raise the quantity' );
    my ($id) = @{ $fake->all_ids('x.basket') };
    $fake->record( 'x.basket', $id )->{qty} = 99;    # somebody else changed it in Odoo
    my $c = confirm_as( $p->{plan}, %STAFF );
    is( $c->{kind},                              'stale', 'refused as stale' );
    is( $fake->record( 'x.basket', $id )->{qty}, 99,      'and the other change stands' );
};

subtest 'an edited plan is refused' => sub {
    my $p    = plan_one();
    my $file = "$d/lazysite/odoo/plans/$p->{plan}/plan.json";
    open my $in, '<', $file or die $!;
    my $h = decode_json( do { local $/; <$in> } );
    close $in;
    $h->{changes}[0]{vals}{qty} = 500;
    open my $out, '>', $file or die $!;
    print {$out} encode_json($h);
    close $out;
    is( confirm_as( $p->{plan}, %STAFF )->{kind}, 'edited', 'the fingerprint no longer matches' );
};

subtest 'an expired plan is refused' => sub {
    my $p    = plan_one();
    my $meta = "$d/lazysite/odoo/plans/$p->{plan}/meta.json";
    open my $in, '<', $meta or die $!;
    my $m = decode_json( do { local $/; <$in> } );
    close $in;
    $m->{created} -= 7200;
    open my $out, '>', $meta or die $!;
    print {$out} encode_json($m);
    close $out;
    is( confirm_as( $p->{plan}, %STAFF )->{kind}, 'expired', 'more than an hour old' );
};

subtest 'the binding as it stands now decides' => sub {
    my $p = plan_one();
    bind( $d, id => 'staff-add', operation => 'shop.add', modes => 'authenticated', callers => 'staff',
        params => 'product=product', fixed => 'basket_key=counter', enabled => 'false' );
    like( confirm_as( $p->{plan}, %STAFF )->{error}, qr/switched off/, 'switched off: refused' );
    bind( $d, id => 'staff-add', operation => 'shop.add', modes => 'authenticated', callers => 'admins',
        params => 'product=product', fixed => 'basket_key=counter' );
    is( confirm_as( $p->{plan}, %STAFF )->{kind}, 'mode', 'its callers changed: refused by the gate' );
    bind( $d, id => 'staff-add', operation => 'shop.add', modes => 'authenticated', callers => 'staff',
        params => 'product=product', fixed => 'basket_key=counter' );
};

subtest 'writes switched off: plans, never applies' => sub {
    write_conf( $d, odoo_url => 'https://odoo.example', odoo_db => 'shopdb', odoo_login => 'site-connection',
        odoo_packs => shop_namespace() );
    my $p = plan_one();
    ok( $p->{planned}, 'a plan is still made' );
    my $n = baskets();
    is( confirm_as( $p->{plan}, %STAFF )->{kind}, 'read-only', 'the apply is refused as read-only' );
    is( baskets(),                                $n, 'and nothing written' );
};

done_testing();
