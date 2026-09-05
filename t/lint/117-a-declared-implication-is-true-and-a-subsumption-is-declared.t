#!/usr/bin/perl
# SM740: whoami presented manage_data and write_data as two independent
# booleans; they are a hierarchy (ANY-OF, SM662), and the field withheld the
# weaker one expecting writes to stop. The fix is presentation: the hierarchy
# is DECLARED (`implied_by`) and carried into describe_capabilities and both
# whoamis.
#
# Two things a declaration must satisfy, and this holds both:
#   1. It is TRUE: every action the implied capability unlocks is also unlocked
#      by the implier, on every channel. A declared implication that is not
#      backed by the unlock lists would be the presentation lying the other way.
#   2. Every subsumption that is NOT declared is exempted here with its reason.
#      manage_services' one unlock (config-set) is also manage_config's, and it
#      is NOT implied - config-set needs BOTH for a service key, an AND - which
#      is why the table is declared rather than derived. A new subsumption fails
#      until somebody decides which it is.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Lazysite::Capabilities qw(describe action_keys implied_by implications);

my $d = describe();
my %unlocks;
for my $c ( action_keys() ) {
    my $u = $d->{capabilities}{$c}{unlocks} || {};
    $unlocks{$c} = { map { $_ => 1 } map { @{ $u->{$_} || [] } } grep { $_ ne 'webdav' && $_ ne 'ui' } keys %$u };
}

my %EXEMPT = (
    'manage_services<manage_config' => 'config-set needs manage_config AND manage_services for a service key - a conjunction, not a hierarchy',
);

subtest 'every declared implication is backed by the unlock lists' => sub {
    my $n = 0;
    for my $c ( action_keys() ) {
        for my $by ( implied_by($c) ) {
            $n++;
            ok( $unlocks{$by}, "$c implied_by $by: $by is a capability with unlocks" ) or next;
            my @missing = grep { !$unlocks{$by}{$_} } sort keys %{ $unlocks{$c} };
            is_deeply( \@missing, [], "$c implied_by $by: every $c unlock is also a $by unlock" );
        }
    }
    ok( $n >= 1, 'at least one implication is declared (write_data by manage_data)' );
    is_deeply( [ implied_by('write_data') ], ['manage_data'], 'write_data is implied by manage_data' );
};

subtest 'every undeclared subsumption is exempted with a reason' => sub {
    my @undecided;
    for my $a ( sort keys %unlocks ) {
        my @ka = keys %{ $unlocks{$a} };
        next unless @ka;
        for my $b ( sort keys %unlocks ) {
            next if $a eq $b;
            next if grep { !$unlocks{$b}{$_} } @ka;      # not subsumed
            next if grep { $_ eq $b } implied_by($a);    # declared
            next if $EXEMPT{"$a<$b"};                    # decided otherwise
            push @undecided, "$a<$b";
        }
    }
    is_deeply( \@undecided, [], 'no subsumption is left undecided' )
        or diag( 'declare implied_by on the weaker capability, or exempt with the reason it is NOT a hierarchy: ' . join( ', ', @undecided ) );
};

subtest 'describe carries it, and holds says satisfied rather than withheld' => sub {
    like( $d->{capabilities}{write_data}{grants}, qr/IMPLIED BY manage_data/, 'the grants sentence names the implier' );
    is_deeply( $d->{capabilities}{write_data}{implied_by}, ['manage_data'], 'and the field is there for a machine' );
    ok( !exists $d->{capabilities}{manage_data}{implied_by}, 'the stronger right declares nothing' );

    my $held = describe( caps => { manage_data => 1, write_data => 0, mcp => 1 } );
    ok( !$held->{holds}{capabilities}{write_data}, 'write_data reports false - it was not granted directly' );
    like( $held->{holds}{why}{write_data}, qr/SATISFIED by manage_data/, 'and why says satisfied, not withheld' );
    is( $held->{holds}{implied}{write_data}{satisfied_by}, 'manage_data', 'the implied block names the implier' );
    like( $held->{holds}{implied}{write_data}{note}, qr/changes nothing/, 'and says what withholding achieves: nothing' );

    my $plain = describe( caps => { write_data => 0, mcp => 1 } );
    like( $plain->{holds}{why}{write_data}, qr/not granted to this account/, 'without the implier, a false is a withholding' );
    is_deeply( $plain->{holds}{implied}, {}, 'and nothing is implied' );

    is_deeply( implications( { manage_data => 1 } ), { write_data => implications( { manage_data => 1 } )->{write_data} }, 'implications: one entry for this grant' );
};

done_testing();
