#!/usr/bin/perl
# SM1347 (ruling 103; OOM 0.44 verify-44): since OOM 0.44 each field a write asked
# for is compared with Odoo's record after it, and a value Odoo dropped or reset in
# the same write leaves the change `done` and not verified. The page is told: the
# change's entry in `result.changes` carries `not_kept` (the field names) and `note`
# (a sentence naming Odoo), and `result.not_verified` is passed. NEVER the asked or
# found values. The same for an immediate apply, a confirmed plan, and the changes a
# resumed unknown run carries. A write Odoo kept carries none of it. In-process, on
# OOM's fake Odoo told to drop the field (`drop_writes`).
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip shop_ready bind quiet);

BEGIN { oom_or_skip() }
use Lazysite::Odoo ();
use Odoo::Error;

my ( $d, $fake ) = shop_ready( shop => { records => { 'x.basket' => [] } } );
bind( $d, id => 'mix', operation => 'shop.mixed', modes => 'authenticated', callers => 'staff',
    apply => 'immediate', params => 'title=title' );
bind( $d, id => 'mix-later', operation => 'shop.mixed', modes => 'authenticated', callers => 'staff',
    params => 'title=title' );

my %SAM = ( mode => 'authenticated', actor => 'sam', groups => ['staff'], caps => {}, ip => '192.0.2.5' );

sub run_b {
    my ( $id, $in, %ctx ) = @_;
    my ( undef, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding($id);
            Lazysite::Odoo::call( $b, $in // {}, strict => 1, %ctx );
    } );
    return $r;
}
sub act { my ( $name, @a ) = @_; return ( quiet( sub { Lazysite::Odoo->can($name)->(@a) } ) )[1] }
sub by_bucket { my ($r) = @_; return { map { ( $_->{bucket} => $_ ) } @{ $r->{result}{changes} || [] } } }
sub reset_shop {
    delete $fake->{fail}{$_}        for keys %{ $fake->{fail} };
    delete $fake->{drop_writes}{$_} for keys %{ $fake->{drop_writes} };
    $fake->record( 'x.product', 1 )->{name} = 'Tea';
}
sub drop_name { $fake->{drop_writes}{'x.product.name'} = 1 }

# What a not-kept change must say, and must not.
sub not_kept_ok {
    my ( $r, $what ) = @_;
    my $c = by_bucket($r)->{rename};
    is( $c->{outcome}, 'done', "$what: the change is still done, as OOM says" ) or diag explain $r;
    is_deeply( $c->{not_kept}, ['name'], "$what: it names the field Odoo did not keep" );
    is( $c->{note}, 'Odoo did not keep this change as asked: name', "$what: and says so, naming Odoo" );
    cmp_ok( $r->{result}{not_verified}, '>=', 1, "$what: not_verified counts it" );
    my $json = encode_json($r);
    unlike( $json, qr/Renamed-\d+/, "$what: never the value asked" );
    unlike( $json, qr/"Tea"/, "$what: never the value found" );
    ok( !exists by_bucket($r)->{line}{not_kept}, "$what: a change Odoo kept carries no not_kept" );
}

subtest 'an immediate apply says which field Odoo did not keep' => sub {
    reset_shop();
    drop_name();
    my $r = run_b( 'mix', { title => 'Renamed-1' }, %SAM );
    ok( $r->{applied}, 'applied' ) or diag explain $r;
    is( $fake->record( 'x.product', 1 )->{name}, 'Tea', 'Odoo kept the old name' );
    not_kept_ok( $r, 'immediate' );
};

subtest 'a confirmed plan says the same' => sub {
    reset_shop();
    drop_name();
    my $p = act( 'action_odoo_run', 'mix-later', { title => 'Renamed-2' }, %SAM, user => 'sam' );
    ok( $p->{planned}, 'a plan' ) or diag explain $p;
    my $c = act( 'action_odoo_confirm', $p->{plan}, %SAM, user => 'sam' );
    ok( $c->{applied}, 'applied' ) or diag explain $c;
    not_kept_ok( $c, 'confirm' );
};

subtest 'a write Odoo kept carries none of it' => sub {
    reset_shop();
    my $r = run_b( 'mix', { title => 'Renamed-3' }, %SAM );
    ok( $r->{applied}, 'applied' ) or diag explain $r;
    is( $fake->record( 'x.product', 1 )->{name}, 'Renamed-3', 'Odoo kept it' );
    ok( !grep( { exists $_->{not_kept} || exists $_->{note} } @{ $r->{result}{changes} } ), 'no change says not kept' );
    is( $r->{result}{not_verified}, 0, 'not_verified is 0' );
};

subtest 'a resumed unknown run says it of the changes it carries' => sub {
    reset_shop();
    $fake->{fail}{'x.product.write'} = Odoo::Error->new( kind => 'transport', sent => 1, write => 1,
        message => 'Timed out while waiting for socket to become ready for reading' );
    my $r = run_b( 'mix', { title => 'Renamed-4' }, %SAM );
    is( $r->{unknown}, 1, 'the rename is unknown' ) or diag explain $r;
    delete $fake->{fail}{'x.product.write'};
    drop_name();
    my ( undef, $s ) = quiet( sub { Lazysite::Odoo::resume( $r->{run}, %SAM ) } );
    ok( $s->{applied}, 'the resume applies the carried rename' ) or diag explain $s;
    not_kept_ok( $s, 'resume' );
};

done_testing;
