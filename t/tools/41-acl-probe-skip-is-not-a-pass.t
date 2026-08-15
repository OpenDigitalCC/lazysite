#!/usr/bin/perl
# SM319: a probe that measured nothing must not read as a pass.
#
# THIS SHAPE HAS NOW SHIPPED TWICE, which is why it gets a test rather than a
# fix. SM285's own status note records the first time:
#
#   IT SHIPPED BROKEN FIRST AND THE TEST CAUGHT IT: the extension list was a
#   file-scoped `my` below the main body ... so the list was EMPTY - zero
#   fetches, 0 == 0, and a verdict of 'the front end respects the ACL' against a
#   port with nothing listening. A security check that passes by testing nothing
#   is the exact defect this programme exists to remove.
#
# The tool was fixed. SM317 then added a deploy-time caller that derived its
# verdict from the ABSENCE of `[ FAIL ]`.
#
# The report named three paths that return before fetching - a bad URL, a docroot
# it cannot write a probe folder into, and an ACL store it cannot write. Reading
# the probe found FIVE outcomes in total, and FOUR of them are not a pass: those
# three, plus a PARTIAL ("could not vouch for some file types") and a no-answer
# ("nothing was served, gated or public"). All four were being announced as
# "front end honours the rule", so fixing only the reported three would have left
# the other two lying in exactly the same way.
#
# Hence the rule here is not "detect the skip" but "require the confirmation":
# the pass branch matches the line the probe prints when it has actually
# established something, and every other outcome - today's four and any added
# later - falls to "not confirmed".
#
# WHY THAT IS WORSE THAN NOT PROBING. The triggering condition is a non-writable
# docroot, which is what a Hestia vhost rebuild produces (SM270) and what edge
# was in on the morning this was written. A deploy runs right after a rebuild.
# So the population the probe would silently absolve is exactly the population it
# exists to catch, and a fleet rollout would report every site clean while
# converting an unknown into a false assurance.
#
# The token is pinned on BOTH sides here, deliberately. The deploy is a shell
# script reading this tool's text output, so the boundary between them is prose -
# and the whole point is that the distinction must survive someone improving the
# wording.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root  = repo_root();
my $check = "$root/tools/lazysite-check.pl";
my $sh    = "$root/installers/hestia/lazysite-hestia-update-all.sh";

ok( -f $check, 'the check tool is present' );
ok( -f $sh,    'the rollout script is present' );

my $chk_src = do { open my $fh, '<', $check or die $!; local $/; <$fh> };
my $sh_src  = do { open my $fh, '<', $sh    or die $!; local $/; <$fh> };

subtest 'the probe has more non-passing outcomes than the report described' => sub {
    # FIVE outcomes, and the reported defect named only one group of them. Worth
    # counting rather than listing, because a sixth added later is the regression
    # this guards.
    my ($probe) = $chk_src =~ /\nsub run_acl_probe \{(.*?)\n\}\n/s;
    ok( $probe, 'run_acl_probe is present' ) or return;

    like( $probe, qr/the front end respects the ACL/,
        'exactly one outcome positively confirms the front end' );
    like( $probe, qr/could not vouch for some file types/,
        'a PARTIAL outcome exists - some types confirmed, others blind' );
    like( $probe, qr/no usable answer/,
        'and a no-answer outcome, where nothing was served either way' );

    my $skipped = () = $probe =~ /ACL PROBE SKIPPED/g;
    cmp_ok( $skipped, '>=', 3,
        'plus the paths that return before fetching, each marked' )
        or diag( 'A path that returns without fetching and does not say so '
            . 'cannot be told apart from one that measured nothing.' );
};

subtest 'the deploy derives a pass from a POSITIVE signal' => sub {
    # This is the whole fix. Absence of FAIL was the bug; absence of anything is
    # equally unsafe, because the probe has four non-passing outcomes and any
    # future fifth would inherit the same treatment. Requiring the probe to SAY
    # it confirmed something makes every unknown fall to "not confirmed", which
    # is the safe direction.
    like( $sh_src, qr/grep -q 'the front end respects the ACL'/,
        'the pass branch matches the confirmation line itself' )
        or diag( 'If the pass is any branch reached by falling through negative '
            . 'tests, every outcome nobody thought of becomes a pass.' );

    # Anchored on the three markers themselves rather than on the shell syntax
    # around them: matching the `if` line character-for-character asserts the
    # formatting, and reformatting is not the regression this guards against.
    my $fail_at = index( $sh_src, 'probe_bad+=' );
    my $pass_at = index( $sh_src, 'probe_ok=$(( probe_ok + 1 ))' );
    my $else_at = index( $sh_src, 'probe_skipped+=' );
    cmp_ok( $fail_at, '>=', 0, 'the branch is present' ) or return;

    cmp_ok( $pass_at, '>', $fail_at, 'the pass is tested after the exposure' );
    cmp_ok( $else_at, '>', $pass_at,
        'and everything else lands in "not confirmed", not in the pass' );
};

subtest 'a probe that confirmed nothing does not fail the deploy' => sub {
    # Absence of evidence, not evidence of exposure. Failing a rollout on it
    # would be wrong, and would also train an operator to ignore the exit
    # status - which is the only signal the exposure case has.
    like( $sh_src, qr/absence of evidence/i,
        'the reasoning is recorded where the decision is made' );

    # The exposure branch sets the failure exit; the not-confirmed branch must
    # not. Scoped to each block rather than matched across the whole file, which
    # is what made the first version of this assertion pass incorrectly.
    my ($skipblk) = $sh_src =~ /(if \[ "\$\{#probe_skipped\[@\]\}" -gt 0 \].*?\n    fi)/s;
    ok( $skipblk, 'the not-confirmed summary block is present' );
    unlike( $skipblk, qr/ACL_PROBE_RC=1/,
        'it does not set the failure exit' );

    my ($badblk) = $sh_src =~ /(if \[ "\$\{#probe_bad\[@\]\}" -gt 0 \].*?\n    fi)/s;
    ok( $badblk, 'the exposure summary block is present' );
    like( $badblk, qr/ACL_PROBE_RC=1/, 'and an exposure still does' );
};

subtest 'the three counts are reported separately' => sub {
    like( $sh_src, qr/%d verified, %d exposed, %d not confirmed/,
        'verified, exposed and not probed are distinct numbers' )
        or diag( 'A site that could not be probed belongs in neither of the '
            . 'first two, and a summary that reports two numbers has to put '
            . 'it in one of them.' );
};

done_testing();
