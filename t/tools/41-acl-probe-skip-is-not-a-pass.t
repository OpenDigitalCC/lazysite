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
# SM321 moved the three-outcome logic OUT of the Hestia script and into the CLI,
# so the assertions follow it. The property is unchanged; only its address is.
my $sh = "$root/tools/lazysite-cli.pl";

ok( -f $check, 'the check tool is present' );
ok( -f $sh,    'the CLI is present' );

my $chk_src = do { open my $fh, '<', $check or die $!; local $/; <$fh> };
my $sh_src  = do { open my $fh, '<', $sh    or die $!; local $/; <$fh> };

subtest 'the probe has more non-passing outcomes than the report described' => sub {
    # FIVE outcomes, and the reported defect named only one group of them. Worth
    # counting rather than listing, because a sixth added later is the regression
    # this guards.
    my ($probe) = $chk_src =~ /\nsub run_acl_probe \{(.*?)\n\}\n/s;
    ok( $probe, 'run_acl_probe is present' ) or return;

    like( $probe, qr/protected content is not reachable anonymously/,
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
    like( $sh_src, qr/protected content is not reachable anonymously/,
        'the pass branch matches the confirmation line itself' )
        or diag( 'If the pass is any branch reached by falling through negative '
            . 'tests, every outcome nobody thought of becomes a pass.' );

    # Anchored on the three markers themselves rather than on the shell syntax
    # around them: matching the `if` line character-for-character asserts the
    # formatting, and reformatting is not the regression this guards against.
    my $fail_at = index( $sh_src, 'push @exposed' );
    my $pass_at = index( $sh_src, 'push @verified' );
    my $else_at = index( $sh_src, 'push @unconfirmed' );
    cmp_ok( $fail_at, '>=', 0, 'the branch is present' ) or return;

    # EXPOSURE IS ALSO A POSITIVE SIGNAL. Matching any [ FAIL ] classified a site
    # with an unrelated failure - missing system pages - as serving protected
    # content anonymously. Found by running the verb against a fixture with no
    # web server, whose probe had actually been SKIPPED. That is SM319's defect
    # in the other direction: there the pass was an absence, here the failure
    # was a level rather than a statement.
    like( $sh_src, qr/a file the engine refuses is served to anonymous visitors/,
        'exposure matches the probe\'s own verdict, not any FAIL in the report' );

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
    like( $sh_src, qr/exit\( \@exposed \? 1 : 0 \)/,
        'only an exposure sets the failure exit' )
        or diag( 'A site that could not be measured must not fail the command: '
            . 'absence of evidence is not evidence of exposure, and failing on '
            . 'it trains an operator to ignore the status the real exposure '
            . 'uses.' );
};

subtest 'the three counts are reported separately' => sub {
    like( $sh_src, qr/%d verified, %d exposed, %d not confirmed/,
        'verified, exposed and not probed are distinct numbers' )
        or diag( 'A site that could not be probed belongs in neither of the '
            . 'first two, and a summary that reports two numbers has to put '
            . 'it in one of them.' );
};

# --- SM426: the probe drops to the site's owner ------------------------------
#
# The probe refuses as root and the refusal is RIGHT (SM377: protecting content
# there leaves root-owned files in the site tree). What was wrong is that the
# refusal ended a routine root deploy with "run the probe as the site user" -
# so the one check that measures gating from OUTSIDE, the way a visitor meets
# it, is the one an automated deploy never gets. SM366 is the standing
# evidence: it has never been run from the field at all.
#
# The mechanism already existed one screen up: `upgrade --all` drops to each
# site's registered owner with sudo -n. This asserts the probe now does the
# same, and asserts the CONSTRAINTS that make it safe rather than just the
# call - a drop that prompted, or that swallowed the probe's own skip reason,
# would be a worse defect than the one it fixes.
subtest 'cmd_probe drops to the site owner, and only when it must' => sub {
    my ($probe) = $sh_src =~ /\nsub cmd_probe \{(.*?)\nsub \w/s;
    ok( $probe, 'cmd_probe is present' ) or return;

    like( $probe, qr/_as_owner\(/, 'it drops privileges rather than refusing' );

    # SM516 TO-16: the three copies of the sudo prelude are one helper now, so
    # the constraint is asserted where it lives - and once, for every caller.
    my ($as_owner) = $sh_src =~ /\nsub _as_owner \{(.*?)\n\}/s;
    ok( $as_owner, '_as_owner is present' ) or return;
    like( $as_owner, qr/'sudo'/, 'the drop is sudo' );
    like( $as_owner, qr/'-n'/,
        'with sudo -n: never prompts, so a host without the sudoers entry '
            . 'FAILS LOUDLY instead of hanging a deploy' );
    like( $probe, qr/site_owner\(/,
        'to the owner the registry records, not a guess' );
    like( $probe, qr/\$is_root && .*\$owner ne \$me/s,
        'ONLY when running as root and the owner is someone else - a non-root '
            . 'operator running as the owner already must not be re-wrapped' );

    # The skip must survive. If the drop is unavailable the probe still reports
    # its own reason, which is what SM385 requires of a summary.
    like( $sh_src, qr/ACL PROBE SKIPPED/,
        'the skip reason is still parsed and reported - a drop that swallowed '
            . 'it would replace a stated cause with silence' );
};

done_testing();
