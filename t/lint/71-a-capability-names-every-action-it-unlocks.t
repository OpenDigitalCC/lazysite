#!/usr/bin/perl
# SM457: a capability must ADVERTISE every control-API action it unlocks.
#
# Actions.pm gates each action on a list of capabilities. Capabilities.pm tells
# a partner what their grant unlocks. Those two are the same fact written
# twice, and nothing checked them against each other on the API plane.
#
# It cost a real operator's agent an afternoon. form-submissions is gated on
# [manage_forms, read_submissions] - either admits it. read_submissions
# advertised it correctly. manage_forms carried NO api list at all, so a
# partner holding it was told about MCP tools and a WebDAV path and nothing
# about the control API, while enforcement let them straight in. They tried
# describe_capabilities, list_form_handlers, forms, form_submissions,
# list_submissions and submissions - six names, none real.
#
# SM435 is this defect pointed the other way: the descriptor CLAIMED a path
# enforcement refused, and t/lint/68 now checks that on the WebDAV plane.
# UNDER-CLAIMING is the quieter half - nothing 403s, nothing errors, the agent
# simply cannot find a door it is holding the key to - so silence is the only
# symptom and a test is the only way to see it.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Lazysite::Capabilities        ();
use Lazysite::ControlApi::Actions ();

my $desc = Lazysite::Capabilities::describe();
my $caps = $desc->{capabilities} || {};

# What each capability CLAIMS on the api plane.
my %claimed;
for my $c ( keys %{$caps} ) {
    $claimed{$c} = { map { $_ => 1 } @{ $caps->{$c}{unlocks}{api} || [] } };
}

# What each capability ACTUALLY unlocks, from the gate.
# %ACTION, not %ACTIONS. The first version of this test named it wrongly and
# skipped itself with "no action table found" - green, silent, and proving
# nothing, which is the exact failure mode the test was written to catch one
# layer down. A skip here would be worse than no test, so it FAILS instead.
my $actions = \%Lazysite::ControlApi::Actions::ACTION;
ok( ref $actions eq 'HASH' && %{$actions},
    'the action table was found' )
    or BAIL_OUT( 'no action table - this test cannot check anything, and '
        . 'must not pass quietly while pretending otherwise' );

my %missing;
for my $a ( sort keys %{$actions} ) {
    my $gate = $actions->{$a}{caps};
    next unless ref $gate eq 'ARRAY' && @{$gate};
    for my $c ( @{$gate} ) {
        next unless exists $claimed{$c};    # not a described capability
        next if $claimed{$c}{$a};
        push @{ $missing{$c} }, $a;
    }
}

if (%missing) {
    for my $c ( sort keys %missing ) {
        fail("$c advertises every API action it unlocks");
        diag( "  missing from its `api` list: "
                . join( ', ', @{ $missing{$c} } ) . "\n"
                . '  A partner holding this capability is admitted to those '
                . "actions and never told they exist.\n"
                . '  That is how an agent ends up guessing names against a '
                . 'surface it cannot see.' );
    }
}
else {
    pass('every capability names the API actions it unlocks');
}

done_testing();
