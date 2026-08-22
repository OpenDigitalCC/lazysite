#!/usr/bin/perl
# SM471: lazysite-check's capability list is a DELIBERATE local copy, pinned
# to the shared one.
#
# WHY A COPY AT ALL. lazysite-check.pl is core-Perl by design - it runs on a
# host where the module tree may not be loadable, which is the whole point of a
# health check - so it cannot import @CAP_KEYS. It carries the list the same
# way the processor carries its ACL copy (ADR 0001), and the same thing makes
# that safe: a test that fails when the two disagree.
#
# WHAT DRIFT WOULD COST. The check exists to tell an operator that their
# manager group is missing a capability this release added - the SM471 defect.
# A stale copy makes it silent about exactly the capability that is newest,
# which is the only one anybody is likely to be missing. It would fail at the
# one job it has, and report OK while doing so.
#
# api and mcp are ABSENT from the copy on purpose: SM127 keeps manager groups
# off the remote channels, so their absence from a manager group is the design
# rather than drift, and a check that flagged them would cry wolf on every
# site.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper               qw(repo_root);
use Lazysite::Auth::Settings ();

my $root = repo_root();
my $src  = do {
    open my $fh, '<', "$root/tools/lazysite-check.pl" or die $!;
    local $/;
    <$fh>;
};

my ($block) = $src =~ /my \@CAPS = qw\(\s*(.*?)\s*\);/s;
ok( defined $block, 'the local capability list was found' )
    or BAIL_OUT( 'no @CAPS in lazysite-check.pl - this test would pass while '
        . 'checking nothing, which is the failure mode it exists to catch one '
        . 'level down' );

my @local  = sort grep { length } split ' ', $block;
my @shared = sort grep { $_ ne 'api' && $_ ne 'mcp' }
    @Lazysite::Auth::Settings::CAP_KEYS;

cmp_ok( scalar @shared, '>', 5, 'the shared list is real (test not vacuous)' );

is_deeply( \@local, \@shared,
    'the check knows exactly the capabilities a manager group should hold' )
    or diag( join "\n  ",
    '',
    'in the shared list, missing from the check: '
        . join( ', ', grep { my $c = $_; !grep { $_ eq $c } @local } @shared ),
    'in the check, not in the shared list: '
        . join( ', ', grep { my $c = $_; !grep { $_ eq $c } @shared } @local ),
    '',
    'A stale copy makes lazysite-check silent about the NEWEST capability - '
        . 'the only one anybody is likely to be missing - so it fails at its '
        . 'one job and reports OK while doing it.' );

subtest 'the remote channels are excluded, and that is deliberate' => sub {
    ok( !( grep { $_ eq 'api' } @local ), 'api is not expected of a manager group' );
    ok( !( grep { $_ eq 'mcp' } @local ), 'nor mcp' )
        or diag( 'SM127 keeps manager groups interactive-only, so flagging '
            . 'these would cry wolf on every site - and a warning that cries '
            . 'wolf trains an operator to skip the one time it is real.' );
};

done_testing();
