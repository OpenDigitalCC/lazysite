#!/usr/bin/perl
# SM1171 (OOM Lab L-13, lazysite-sites agent): "An applied write answers
# `counts` and `by_bucket` only: the hold REASON ... and a change's `returned`
# value (e.g. the backorder's name) never reach the page." The plan answer
# carries each change's reason; the apply answer (immediate and confirmed)
# carries, per change, seq bucket action model id outcome, `reason` for a
# held or skipped change and `returned` for a custom change - and nothing else
# of it. `returned` is capped at 4 KB.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip shop_ready bind quiet);

BEGIN { oom_or_skip() }
use Lazysite::Odoo ();

# OOM's runner finds a custom change's handler in ITS default registry, which
# knows the site's packs only through this variable; the engine sets it for the
# lookup of an operation and not for the apply, so a pack's own handler needs it
# set here (a finding, filed with SM1171). The handlers the Lab uses are OOM's
# own and need nothing.
$ENV{ODOO_OPS_NAMESPACES} = 'LazysiteTest::OdooOps';

my ( $d, $fake ) = shop_ready();
bind( $d, id => 'ship', operation => 'shop.ship', modes => 'authenticated', callers => 'staff',
    params => 'product=product,size=size' );
bind( $d, id => 'quick', operation => 'shop.ship', modes => 'public', apply => 'immediate',
    params => 'product=product,size=size' );

my %SAM = ( user => 'sam', groups => ['staff'], caps => {}, ip => '192.0.2.5', channel => 'api' );

sub act { my ( $name, @a ) = @_; return ( quiet( sub { Lazysite::Odoo->can($name)->(@a) } ) )[1] }

sub quick {
    my (%p) = @_;
    my ( undef, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding('quick');
            Lazysite::Odoo::call( $b, {%p}, mode => 'public', visitor_key => undef, ip => '192.0.2.9' );
    } );
    return $r;
}

sub by_bucket { my ($r) = @_; return { map { ( $_->{bucket} => $_ ) } @{ $r->{result}{changes} || [] } } }

subtest 'a plan says why a change will be held' => sub {
    my $p = act( 'action_odoo_run', 'ship', { product => 1 }, %SAM );
    ok( $p->{planned}, 'a plan' ) or diag explain $p;
    my ($held) = grep { $_->{action} eq 'hold' } @{ $p->{preview}{changes} };
    is( $held->{reason}, 'only 1 of product 1 on hand', 'the hold carries its reason' );
    my ($made) = grep { $_->{action} eq 'create' } @{ $p->{preview}{changes} };
    ok( !exists $made->{reason}, 'a change with no reason carries none' );
    ok( !exists $held->{vals}, 'values stay out of the plan view' );
};

subtest 'an immediate apply answers the reason and the returned value' => sub {
    my $r = quick( product => 1 );
    ok( $r->{applied}, 'applied' ) or diag explain $r;
    my $c = by_bucket($r);
    is( $c->{short}{reason}, 'only 1 of product 1 on hand', 'the hold reason' );
    is( $c->{short}{outcome}, 'held', 'it was held' );
    is( $c->{short}{seq}, 1, 'seq' );
    is( $c->{short}{model}, 'x.basket', 'model' );
    is( $c->{short}{id}, 7, 'record id' );
    is( $c->{backorder}{returned}, 'BO/00042', 'a custom change answers its returned value' );
    is( $c->{backorder}{action}, 'custom', 'action' );
    ok( !exists $c->{backorder}{reason}, 'no reason on a done change' );
    ok( !exists $c->{'new-line'}{returned}, 'returned only on a custom change' );
    like( $c->{'new-line'}{id}, qr/^\d+$/, 'a created record names its id' );
};

subtest 'a confirmed plan answers the same' => sub {
    my $p = act( 'action_odoo_run', 'ship', { product => 1 }, %SAM );
    my $c = act( 'action_odoo_confirm', $p->{plan}, %SAM );
    ok( $c->{applied}, 'applied' ) or diag explain $c;
    my $b = by_bucket($c);
    is( $b->{short}{reason}, 'only 1 of product 1 on hand', 'the hold reason' );
    is( $b->{backorder}{returned}, 'BO/00042', 'the returned value' );
};

subtest 'an oversized returned is capped and says so' => sub {
    my $r = quick( product => 1, size => 100000 );
    ok( $r->{applied}, 'applied' ) or diag explain $r;
    my $ret = by_bucket($r)->{backorder}{returned};
    ok( length($ret) < 5000, 'under the cap, not 100000' ) or diag length $ret;
    like( $ret, qr/truncated/, 'the marker says so' );
    like( $ret, qr/\Ax{100}/, 'the head is kept' );
};

subtest 'nothing else of the change leaks' => sub {
    my $r = quick( product => 1 );
    my $json = JSON::PP->new->canonical->encode($r);
    unlike( $json, qr/internal-note-hold|internal-secret-vals/, 'no value the caller did not send' );
    unlike( $json, qr/journal/, 'no journal path' );
    for my $ch ( @{ $r->{result}{changes} } ) {
        my @bad = grep { !/^(?:seq|bucket|action|model|id|outcome|reason|returned)$/ } keys %$ch;
        is_deeply( \@bad, [], "change $ch->{seq}: only the named fields" ) or diag "@bad";
    }
    my $p = act( 'action_odoo_run', 'ship', { product => 1 }, %SAM );
    unlike( JSON::PP->new->encode($p), qr/internal-note-hold|internal-secret-vals/, 'plan view: no values' );
};

done_testing;
