#!/usr/bin/perl
# N141B-G: the users tool's POD does not name a command the tool does not have.
#
# SM659 renamed `setup-manager` to `setup-sysop` and deliberately left NO alias
# - the old name created a role account by default, which is the thing the
# rename fixes. The dispatcher was updated. The POD was not, and went on saying
# "C<setup-manager> - one command to create the manager account" for four
# releases, under the heading "Bootstrap".
#
# WHERE IT LANDS. `perldoc lazysite-users.pl` is what an operator reads BEFORE
# their first successful command, so the one page they consult first named the
# one command that would not run - and the reply to a name the dispatcher does
# not know says only that it is unknown, not what replaced it.
#
# The site agent found it by reading, and said the thing that mattered: "the new
# lint does not read POD". Every gate in this tree checks code against code or
# doc against doc. A manual describing a CLI is a claim about that CLI, and
# nothing was comparing them.
#
# WHAT THIS DOES NOT DO: it does not require every command to be documented.
# Some are internal, and a rule that forced them all into the manual would push
# noise at the reader to satisfy a test. It checks the direction that misleads -
# a name in the MANUAL that the DISPATCHER will refuse.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $tool = repo_root() . '/tools/lazysite-users.pl';
open my $fh, '<', $tool or BAIL_OUT("no users tool: $!");
my $src = do { local $/; <$fh> };
close $fh;

my ( $code, $pod ) = split /^=head1/m, $src, 2;
ok( length $pod, 'the tool carries POD' ) or do { done_testing(); exit };

# --- what the dispatcher actually accepts ------------------------------------
#
# Read from the elsif chain that routes $cmd, which is the thing that decides.
my %verb;
$verb{$1} = 1 while $code =~ /\$cmd\s+eq\s+'([a-z0-9][a-z0-9-]*)'/g;
cmp_ok( scalar keys %verb, '>', 20, 'the dispatch table was found and read' )
    or diag( 'If the routing stopped being an elsif chain on $cmd, this test '
        . 'is reading nothing and would pass on anything. Fix the extraction '
        . 'before trusting a green run.' );
ok( $verb{'setup-sysop'}, 'setup-sysop is a real command' );
ok( !$verb{'setup-manager'},
    'setup-manager is NOT - SM659 removed it with no alias' )
    or diag( 'If the alias came back, this test\'s premise changed: decide '
        . 'whether the manual should name it again.' );

# --- every command the MANUAL names in a command list ------------------------
#
# Only the C<...> entries that look like CLI verbs - lowercase, hyphenated. The
# POD also uses C<> for file names, config keys and Perl symbols, and those are
# not claims about the dispatcher.
#
# A DEAD NAME MAY APPEAR WHEN THE MANUAL IS SAYING IT IS DEAD. "renamed from
# C<setup-manager>, no alias" is the most useful sentence on the page for
# somebody holding an old runbook, and a rule that refused it would push the
# manual towards silence about its own history. So a match is excused when the
# text around it retires it in as many words - and only then.
my %named;
while ( $pod =~ /C<([a-z][a-z0-9]*(?:-[a-z0-9]+)+)>/g ) {
    my $name = $1;
    my $from = $-[0] < 200 ? 0 : $-[0] - 200;
    my $near = substr $pod, $from, 400;
    next if $near =~ /\b(?:renamed|removed|no alias|does not exist|retired)\b/i;
    $named{$name} = 1;
}
cmp_ok( scalar keys %named, '>', 10, 'the manual names commands to check' );

my @ghosts = sort grep { !$verb{$_} } keys %named;

# Names the manual may use that are not $cmd verbs of THIS tool: other
# executables, another surface's actions, and argument grammar belonging to a
# verb rather than being one.
my %ALLOWED = map { $_ => 1 } qw(
    lazysite-users lazysite-check lazysite-hestia-domain
    update-policy update-channel home-domain dav-scope
    describe-capabilities
);
@ghosts = grep { !$ALLOWED{$_} } @ghosts;

is_deeply( \@ghosts, [],
    'every hyphenated command the manual names is one the tool will run' )
    or diag( "The manual names commands the dispatcher does not have:\n  "
        . join( "\n  ", @ghosts )
        . "\n\nEither the command was renamed and the manual kept the old name "
        . "- which is what SM659 left behind, and what sends an operator to a "
        . "command that cannot run - or this is not a CLI verb at all, in which "
        . "case add it to \%ALLOWED above with a word about what it is." );

done_testing();
