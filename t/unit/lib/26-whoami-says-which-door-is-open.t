#!/usr/bin/perl
# SM491: whoami says which of the grant's channels can reach each capability.
#
# THE FIELD CASE. An operator granted analytics so an agent could check an
# access log. whoami said analytics:true. whoami said mcp:false. The agent
# tried ?action=analytics, got "Unrecognised action name", and concluded the
# capability had no surface on its grant. It did - the action is named
# analyse_visitors and is gated on analytics over the API - but nothing told
# them, and a bare `true` is not operationally true when the only door the
# agent tried was the wrong one and the door they assumed was shut.
#
# So whoami now derives, per held capability, which channels of THIS grant
# reach it and which would but are off. Derived from the unlocks map rather
# than declared, so it cannot drift from what the surfaces actually offer.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Lazysite::Capabilities ();

sub reach { Lazysite::Capabilities::reachability( { @_ } ) }

subtest "THE REPORTER'S GRANT: analytics on, mcp off" => sub {
    my $r = reach( analytics => 1, api => 1, mcp => 0 );
    ok( $r->{analytics}, 'analytics is reported' );
    is_deeply( $r->{analytics}{via}, ['api'], 'reachable via the API - which the agent did not know' )
        or diag( 'The route is analyse_visitors over the control API. It was '
            . 'there the whole time; the agent guessed the wrong name.' );
    is_deeply( $r->{analytics}{requires}, ['mcp'], 'and mcp would also reach it, but is off' )
        or diag( 'This is the half the reporter saw: a door that exists and '
            . 'is shut on a different switch.' );
};

subtest 'every door shut: held, and reachable nowhere' => sub {
    my $r = reach( analytics => 1, api => 0, mcp => 0 );
    is_deeply( $r->{analytics}{via}, [], 'reachable on no channel of this grant' );
    is_deeply( [ sort @{ $r->{analytics}{requires} } ], [qw(api mcp)], 'both would, both are off' )
        or diag( 'This is the case the original report described. The operator '
            . 'sees the grant applied and the agent sees the capability held.' );
};

subtest 'every door open: no requires key at all' => sub {
    my $r = reach( analytics => 1, api => 1, mcp => 1 );
    ok( !exists $r->{analytics}{requires}, 'nothing is missing, so nothing is named' )
        or diag( 'An empty requires list on every capability would train an '
            . 'agent to ignore the key.' );
};

subtest 'a capability the grant does not hold is not listed' => sub {
    my $r = reach( api => 1, mcp => 1 );
    ok( !exists $r->{analytics}, 'analytics absent when not held' );
};

subtest 'it is DERIVED from the unlocks map, not a hand-list' => sub {
    # Any capability with an api or mcp surface must appear when held with
    # both channels on; a hand-list would silently omit the next one added.
    my %all = map { $_ => 1 } Lazysite::Capabilities::capability_keys();
    my $r = reach( %all, api => 1, mcp => 1 );
    my $n = scalar keys %{$r};
    cmp_ok( $n, '>=', 5, "$n capabilities have a remote surface and are all reported" );
    ok( $r->{manage_data}, 'including manage_data, which arrived after the original hand-lists' );
};

done_testing();
