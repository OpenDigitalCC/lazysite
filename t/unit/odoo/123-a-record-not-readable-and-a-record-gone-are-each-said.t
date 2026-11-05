#!/usr/bin/perl
# SM1347 (ruling 104; OOM 0.43 fields-43): OOM tells a record the account may not
# read (`refused/access`) from one that does not exist (`refused/missing`). Each
# reaches the caller with a sentence of its own, naming Odoo, where both said the
# generic "the call was refused before Odoo answered" - which is wrong for both:
# Odoo did answer. The kind stays `refused`, so no page that handles it changes.
# OOM's own text stays in the log, as every fault's does (t/unit/odoo/02).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip shop_ready bind quiet);

BEGIN { oom_or_skip() }
use Odoo::Error;
use Lazysite::Odoo ();

my $OOM_TEXT = 'core.get: x.product has no record with id 99 (/srv/odoo/runs/abc)';

my %SAID = (
    access  => 'Odoo refused: this account may not do that',
    missing => 'that record no longer exists in Odoo',
);

sub fault_of {
    my ($code) = @_;
    my $err = Odoo::Error->new( kind => 'refused', code => $code, message => $OOM_TEXT );
    my ( $log, $r ) = quiet( sub { Lazysite::Odoo::fault( $err, binding => 'b1', operation => 'shop.add', mode => 'public' ) } );
    return ( $r, $log );
}

for my $code ( sort keys %SAID ) {
    subtest "refused/$code is said as what it is" => sub {
        my ( $r, $log ) = fault_of($code);
        is( $r->{kind},  'refused',     'the kind is refused, as before' ) or diag explain $r;
        is( $r->{error}, $SAID{$code}, 'with its own sentence' );
        unlike( $r->{error}, qr/before Odoo answered/, 'not the generic one' );
        unlike( join( ' ', values %$r ), qr/core\.get|\/srv\//, 'OOM\'s text is not returned' );
        like( $log, qr/core\.get/, 'it is logged' );
    };
}

subtest 'another refusal code keeps the generic sentence' => sub {
    my ($r) = fault_of('no-such-code');
    is( $r->{error}, 'the call was refused before Odoo answered', 'unchanged' );
};

subtest 'through a binding: a read refused for access answers its sentence' => sub {
    my ( $d, $fake ) = shop_ready();
    bind( $d, id => 'list', operation => 'shop.products', modes => 'public' );
    $fake->{fail}{'x.product.search_read'} = Odoo::Error->new( kind => 'refused', code => 'access', message => $OOM_TEXT );
    my ( undef, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding('list');
            Lazysite::Odoo::call( $b, {}, mode => 'public', ip => '192.0.2.4', strict => 1 );
    } );
    ok( !$r->{ok}, 'refused' ) or diag explain $r;
    is( $r->{kind},  'refused',        'kind refused' );
    is( $r->{error}, $SAID{access}, 'and the access sentence' );
};

done_testing;
