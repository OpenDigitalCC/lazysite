#!/usr/bin/perl
# SM1193 (OOM Lab L-19): "A failed apply reaches the page as `apply-incomplete`,
# with counts and no message. Odoo's refusal is in the journal only." OOM's answer
# (inbox 2026-10-20): the result carries `failed_changes` - key, model, action and
# Odoo's `message`. The apply's `changes` (SM1171) carries them: the failed change's
# entry has key, message (and code when OOM sends one), the message passed through
# SM1186's filter; a change that was done beside it is still `done`.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip shop_ready bind quiet);

BEGIN { oom_or_skip() }
use Lazysite::Odoo ();
use Odoo::Error;

my ( $d, $fake ) = shop_ready();
bind( $d, id => 'mix', operation => 'shop.mixed', modes => 'authenticated', callers => 'staff',
    params => 'title=title' );
bind( $d, id => 'quick', operation => 'shop.mixed', modes => 'public', apply => 'immediate',
    params => 'title=title' );
my %SAM = ( user => 'sam', groups => ['staff'], caps => {}, ip => '192.0.2.5', channel => 'api' );

sub refuse { my ($msg) = @_; $fake->{fail}{'x.basket.create'} = Odoo::Error->new( kind => 'fault', message => $msg, fault_class => 'odoo.exceptions.UserError' ) }
sub quick {
    my ( undef, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding('quick');
            Lazysite::Odoo::call( $b, {}, mode => 'public', visitor_key => undef, ip => '192.0.2.9' );
    } );
    return $r;
}
sub by_bucket { my ($r) = @_; return { map { ( $_->{bucket} => $_ ) } @{ $r->{result}{changes} || [] } } }

subtest 'an immediate apply says which change Odoo refused, and why' => sub {
    refuse('You can not enter an attendance in a submitted timesheet');
    my $r = quick();
    ok( !$r->{ok}, 'not ok' );
    is( $r->{kind}, 'apply-incomplete', 'apply-incomplete' ) or diag explain $r;
    my $c = by_bucket($r);
    is( $c->{line}{outcome}, 'failed', 'the line failed' );
    is( $c->{line}{key}, 'line:1', 'with its key' );
    is( $c->{line}{model}, 'x.basket', 'its model' );
    is( $c->{line}{action}, 'create', 'its action' );
    is( $c->{line}{message}, 'You can not enter an attendance in a submitted timesheet', "and Odoo's message" );
    ok( !$c->{line}{withheld}, 'not withheld' );
    is( $c->{rename}{outcome}, 'done', 'the change beside it is still done' );
    ok( !exists $c->{rename}{message}, 'and carries no message' );
    is( scalar @{ $r->{result}{changes} }, 2, 'one shape: two entries, not a second list' );
    ok( !exists $r->{result}{failed_changes}, 'no second list beside it' );
};

subtest 'a confirmed plan says the same' => sub {
    refuse('The period is closed');
    my ( undef, $p ) = quiet( sub { Lazysite::Odoo::action_odoo_run( 'mix', {}, %SAM ) } );
    ok( $p->{planned}, 'planned' ) or diag explain $p;
    my ( undef, $c ) = quiet( sub { Lazysite::Odoo::action_odoo_confirm( $p->{plan}, %SAM ) } );
    is( $c->{kind}, 'apply-incomplete', 'apply-incomplete' ) or diag explain $c;
    is( by_bucket($c)->{line}{message}, 'The period is closed', "Odoo's message" );
    is( by_bucket($c)->{line}{key}, 'line:1', 'key' );
};

subtest 'a message with a path, a trace or a secret is withheld' => sub {
    for my $m ( "Cannot open /opt/odoo/addons/hr/models/x.py", 'Boom at /usr/lib/x.pm line 12.',
        'Invalid password for admin', 'Traceback (most recent call last):' ) {
        refuse($m);
        my $r = quick();
        my $l = by_bucket($r)->{line};
        ok( !defined $l->{message} || $l->{message} !~ /opt|usr|assword|Traceback/, "withheld: $m" ) or diag explain $l;
        ok( $l->{withheld}, 'and says so' );
        is( $l->{key}, 'line:1', 'the key stays' );
        is( $l->{outcome}, 'failed', 'still failed' );
    }
};

subtest 'a long message is cut, control characters go' => sub {
    refuse( "Line one\n\tline two " . ( 'word ' x 100 ) );
    my $l = by_bucket( quick() )->{line};
    unlike( $l->{message}, qr/[\x00-\x1f]/, 'no control characters' );
    cmp_ok( length $l->{message}, '<=', 300, 'capped' );
};

subtest 'an applied change that did not fail carries no failure fields' => sub {
    delete $fake->{fail}{'x.basket.create'};
    my $r = quick();
    ok( $r->{ok}, 'applied' ) or diag explain $r;
    for my $ch ( @{ $r->{result}{changes} } ) {
        ok( !exists $ch->{key} && !exists $ch->{message}, "change $ch->{seq}: no failure fields" );
    }
};

done_testing;
