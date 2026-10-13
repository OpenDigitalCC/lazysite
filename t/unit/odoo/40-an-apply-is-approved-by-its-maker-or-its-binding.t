#!/usr/bin/perl
# SM747 + OOM's run registry (2026-10-13): OOM's Runner refuses to apply a plan
# that nobody approved, unless the config says approval = none. Lazysite's
# confirm IS that approval - the account or visitor that made the plan says
# apply - and so is a binding's `apply: immediate` (the operator's standing
# approval of that one operation). So the engine records the approval, by whom,
# against the plan's fingerprint, immediately before it applies - and OOM's own
# gate stays ON: nothing here sets approval = none.
#
# What this holds:
#   * a confirmed plan applies, and the run record says it was approved by the
#     maker (the owner label), not by something else;
#   * an immediate apply applies, approved by the BINDING;
#   * a plan nobody confirmed is never approved, and so is never applied by OOM
#     even if something called apply on it;
#   * somebody else's confirm approves nothing.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
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

sub run_record {
    my ($pid) = @_;
    open my $fh, '<', Lazysite::Odoo::plans_dir() . "/$pid/run.json" or return undef;
    local $/;
    return eval { decode_json(<$fh>) };
}

subtest 'a confirm is the maker\'s approval, recorded, and OOM\'s gate stays on' => sub {
    my $p = act( 'action_odoo_run', 'order', { product => 1 }, %SAM );
    ok( $p->{planned}, 'a plan' ) or diag explain $p;
    my $before = run_record( $p->{plan} );
    ok( !$before || !$before->{approval}, 'nothing approved it yet' );
    my $c = act( 'action_odoo_confirm', $p->{plan}, %SAM );
    ok( $c->{applied}, 'confirmed: applied' ) or diag explain $c;
    my $r = run_record( $p->{plan} );
    is( $r->{state},        'applied',     'the run is applied' );
    is( $r->{approval}{by}, 'account:sam', 'approved by its maker' );
    like( $r->{approval}{note}, qr/confirmed in lazysite/, 'saying so' );
    is( $r->{approval}{fingerprint}, $r->{fingerprint}, 'against this plan\'s own fingerprint' );
    is( scalar @{ $fake->all_ids('x.basket') }, 1, 'and it is in Odoo' );
};

subtest 'an immediate binding approves its own apply' => sub {
    my ( undef, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding('quick');
            Lazysite::Odoo::call( $b, { product => 2 }, mode => 'public', visitor_key => undef, ip => '192.0.2.9' );
    } );
    ok( $r->{applied}, 'applied in the same request' ) or diag explain $r;
    my $run = run_record( $r->{plan} );
    is( $run->{approval}{by}, 'binding:quick', 'approved by the binding' );
    like( $run->{approval}{note}, qr/apply: immediate/, 'and says why' );
};

subtest 'nobody else\'s confirm approves anything, and an unconfirmed plan stays unapproved' => sub {
    my $p     = act( 'action_odoo_run',     'order',    { product => 2 }, %SAM );
    my $other = act( 'action_odoo_confirm', $p->{plan}, %SAM,             user => 'tom' );
    is( $other->{kind}, 'not-found', 'another account is told there is no such plan' );
    my $r = run_record( $p->{plan} );
    ok( !$r || !$r->{approval}, 'and it approved nothing' );
    my $lines = scalar @{ $fake->all_ids('x.basket') };
    require Odoo::Ops::Plan;
    require Odoo::Ops::Runner;
    my $dir = Lazysite::Odoo::plans_dir() . "/$p->{plan}";
    my $err = eval {
        my $plan = Odoo::Ops::Plan->load("$dir/plan.json");
        my $ctx = Lazysite::Odoo::context( ( Lazysite::Odoo::connection() )[0], actor => 'x' );
        $ctx->use_run_dir($dir);
        Odoo::Ops::Runner->apply( $ctx, $plan, dir => $dir );
        undef;
    } // $@;
    ok( ref $err && $err->{code} && $err->{code} eq 'unapproved', 'OOM itself refuses to apply it (unapproved)' )
        or diag explain $err;
    is( scalar @{ $fake->all_ids('x.basket') }, $lines, 'nothing reached Odoo' );
};

done_testing();
