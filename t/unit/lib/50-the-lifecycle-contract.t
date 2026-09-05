#!/usr/bin/perl
# SM222: the lifecycle contract, and the disagreement it exists to name.
#
# A service reported enabled or not enabled, so an operator could not tell "off
# because I turned it off" from "off because it died" - one word for opposite
# problems, and the second one silent.
#
# The contract separates INTENT from OBSERVATION and derives the verdict from
# both, in one place. That last part is the property worth protecting: if each
# unit decided for itself what `inconsistent` meant, the vocabulary would drift
# exactly the way SM662 documents, and a shared word that means different things
# per surface is worse than no shared word.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Lifecycle qw(lifecycle_status verdicts is_verdict);

subtest 'off because you turned it off is HEALTHY' => sub {
    # The case most likely to be got wrong. A unit that is off on purpose is
    # not a problem, and reporting it as one trains an operator to ignore the
    # panel - which is how a real failure goes unnoticed.
    my $s = lifecycle_status( unit => 'webdav', desired_on => 0, running => 0 );

    is( $s->{desired}, 'off', 'desired off' );
    is( $s->{verdict}, 'off', 'verdict off' );
    is( $s->{healthy}, 1,     'and HEALTHY - nothing is wrong' );
    ok( !exists $s->{remedy},
        'with no remedy, because there is nothing to remedy' );
};

subtest 'on and running' => sub {
    my $s = lifecycle_status( unit => 'webdav', desired_on => 1, running => 1 );
    is( $s->{verdict}, 'on', 'verdict on' );
    is( $s->{healthy}, 1,    'healthy' );
    ok( !exists $s->{remedy}, 'and no remedy' );
};

subtest 'the disagreement - on but not running' => sub {
    # THE WHOLE POINT. Config says on, reality says no.
    my $s = lifecycle_status( unit => 'webdav', desired_on => 1, running => 0 );

    is( $s->{desired}, 'on',           'desired stays on - intent is unchanged' );
    is( $s->{verdict}, 'inconsistent', 'and the verdict names the gap' );
    is( $s->{healthy}, 0,              'not healthy' );

    like( $s->{message}, qr/switched on but is not running/,
        'the message says it in words an operator reads' );
    ok( length( $s->{remedy} // '' ),
        'AND a remedy - four filings this week were about states with no action' );
};

subtest 'starting is not the same as inconsistent' => sub {
    # A unit mid-start is not broken, and calling it inconsistent would make
    # every restart look like a fault.
    my $s = lifecycle_status(
        unit => 'daemon', desired_on => 1, running => 0, starting => 1 );
    is( $s->{verdict}, 'starting', 'a start in flight is its own verdict' );
    is( $s->{healthy}, 0,          'not yet healthy, but not a fault either' );
};

subtest 'degraded is running-but-hurt, not stopped' => sub {
    my $s = lifecycle_status(
        unit => 'daemon', desired_on => 1, running => 1, degraded => 1 );
    is( $s->{verdict}, 'degraded', 'running and degraded' );
    is( $s->{healthy}, 0,          'reported as unhealthy' );
};

subtest 'a caller may assert a verdict it knows better than we can derive' => sub {
    # A unit that TRIED and could not knows `failed`; no amount of looking at
    # desired-versus-running can distinguish that from never having tried.
    my $s = lifecycle_status(
        unit    => 'scheduler', desired_on => 1,         running => 0,
        verdict => 'failed',    message    => 'it died', remedy  => 'read the log' );
    is( $s->{verdict}, 'failed',       'the asserted verdict wins' );
    is( $s->{message}, 'it died',      'and the caller\'s sentence is kept' );
    is( $s->{remedy},  'read the log', 'as is its remedy' );
};

subtest 'the vocabulary is closed, and sayable' => sub {
    my @v = verdicts();
    cmp_ok( scalar @v, '>=', 6, 'the set is real' );
    ok( is_verdict('inconsistent'), 'a known verdict is known' );
    ok( !is_verdict('wobbly'),      'an invented one is not' );
    ok( !is_verdict(undef),         'and undef is not a verdict' );

    # Every verdict must produce a message, or a unit in that state tells an
    # operator nothing. Cheap to assert, and the kind of gap that appears when
    # a seventh verdict is added later.
    for my $verdict (@v) {
        my $s = lifecycle_status(
            unit => 'u', desired_on => 1, running => 0, verdict => $verdict );
        ok( length( $s->{message} // '' ), "$verdict has a message" );
        next if $s->{healthy};
        ok( length( $s->{remedy} // '' ), "$verdict has a remedy" );
    }
};

done_testing();
