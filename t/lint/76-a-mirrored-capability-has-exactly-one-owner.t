#!/usr/bin/perl
# ADR 0009 / SM447: a capability declared by a plugin is MIRRORED in the core
# lists, and the mirror must have exactly one owner.
#
# WHY A MIRROR AT ALL. ADR 0009 says the platform should consume the plugin's
# declaration rather than know the plugin by name, and that conformance REMOVES
# entries from core lists rather than adding to them. The runtime cannot follow
# that literally here: `caps_for()` is consulted on every request through every
# channel, and discovering capabilities by running each plugin's `--describe`
# would put ten subprocesses on the request path. That is not a trade worth
# making for a list that changes when a release ships.
#
# So the runtime keeps a static list and THIS TEST does the discovering, which
# is the ADR's other sentence read exactly: "the contract does not exempt a
# plugin from the lints, it makes the lints discover the plugin's entries".
#
# WHAT IT REFUSES, and each is a state that would otherwise be silent:
#
#   A mirror with NO owner - a capability sitting in @CAP_KEYS that no plugin
#   declares and that core does not implement either. It is grantable in the UI
#   and unlocks nothing, which reads to an operator as a broken permission.
#
#   TWO owners - two plugins declaring one capability. Whichever is asked
#   answers for both, and disabling one leaves the other's grant half-live.
#   This is the ambiguity ADR 0009 exists to remove.
#
#   A declaration with NO mirror - a plugin claiming a capability that is not
#   in @CAP_KEYS. It cannot be granted, so the plugin's actions are unreachable
#   and nothing says why.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use Lazysite::Auth::Settings ();
use Lazysite::Capabilities   ();

my $root    = "$FindBin::Bin/../..";
my $plugins = "$root/plugins";
plan skip_all => 'no plugins directory' unless -d $plugins;

# Every capability every plugin claims, and who claims it.
my %claimed_by;
for my $f ( sort glob "$plugins/*.pl" ) {
    # SM666: SCALAR FIRST, and this is not style. Backticks in LIST context
    # return a list of LINES, so `decode_json(`...`)` passed decode_json only
    # the first line of the output. Every plugin that existed when this was
    # written printed compact single-line JSON, so the first line was the whole
    # document and the bug was invisible. The first plugin to pretty-print its
    # --describe simply vanished from this check - a capability-ownership lint
    # that under-reports and says nothing, which is the failure mode it exists
    # to prevent in others.
    my $raw = `$^X \Q$f\E --describe 2>/dev/null`;
    my $d   = eval { decode_json($raw) };

    next unless ref $d eq 'HASH' && ref $d->{owns} eq 'HASH';
    my $id = $d->{id} // ( $f =~ s{.*/}{}r );
    push @{ $claimed_by{$_} }, $id
        for @{ $d->{owns}{capabilities} || [] };
}

my %cap_key   = map { $_ => 1 } @Lazysite::Auth::Settings::CAP_KEYS;
my $desc      = Lazysite::Capabilities::describe();
my $described = $desc->{capabilities} || {};

subtest 'no capability is claimed by two plugins' => sub {
    my @twice = grep { @{ $claimed_by{$_} } > 1 } sort keys %claimed_by;
    is_deeply( \@twice, [], 'each declared capability has one owner' )
        or diag( join "\n  ", '',
        map { "$_ is claimed by: " . join( ', ', @{ $claimed_by{$_} } ) } @twice );
};

subtest 'every declared capability is grantable' => sub {
    for my $c ( sort keys %claimed_by ) {
        ok( $cap_key{$c},
            "$c (declared by $claimed_by{$c}[0]) is in \@CAP_KEYS" )
            or diag( 'A capability that is not in @CAP_KEYS cannot be granted '
                . 'to anybody, so the plugin\'s actions are unreachable and '
                . 'nothing says why.' );
        ok( $described->{$c}, "$c is described in Lazysite::Capabilities" )
            or diag( 'describe-capabilities is how a partner learns what it '
                . 'holds. An undescribed capability is one an agent cannot '
                . 'discover.' );
    }
};

# The other direction is the one that catches a stale mirror. It needs to know
# which capabilities core implements itself, and that list is here rather than
# derived because deriving it is the thing being checked - a core capability is
# simply one no plugin claims, which would make this assertion vacuous.
my %CORE = map { $_ => 1 } qw(
    ui webdav api mcp
    manage_content manage_nav manage_forms manage_themes manage_layouts
    manage_domains manage_config manage_services manage_users
    analytics audit notifications feedback read_submissions
    housekeeping purge
    create_sub_users delegate_sub_user_creation);

subtest 'no capability is grantable with nobody implementing it' => sub {
    my @orphan = grep { !$CORE{$_} && !$claimed_by{$_} }
        sort @Lazysite::Auth::Settings::CAP_KEYS;
    is_deeply( \@orphan, [], 'every @CAP_KEYS entry is core or plugin-owned' )
        or diag( join "\n  ", '', @orphan, '',
        'These are grantable in the UI and unlock nothing. To an operator '
            . 'that reads as a broken permission, and there is no error '
            . 'anywhere to lead them to the cause. Either a plugin should be '
            . 'declaring it, or the mirror is stale and should be removed.' );
};

subtest 'the check can actually see something' => sub {
    # A guard that runs before any plugin declares a capability would pass
    # every assertion above while proving nothing. SM447's data plugin is
    # ADR 0009's exemplar; if it stops declaring, this test has no subject.
    ok( scalar keys %claimed_by,
        'at least one plugin declares a capability' )
        or diag( 'With no declarations this test is green and empty - the '
            . 'exact failure mode it exists to catch one layer down.' );
};

done_testing();
