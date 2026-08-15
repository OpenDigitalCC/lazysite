#!/usr/bin/perl
# SM309: front-door mode is a yes/no value, and something says which it is.
#
# TWO DEFECTS IN ONE OPERATOR STEP, which is why they are tested together.
#
# 1. FRONT_DOOR=false switched it ON. The launcher tested
#    `length($ENV{FRONT_DOOR}) && $ENV{FRONT_DOOR} ne '0'`, so every non-empty
#    value except '0' meant yes - false, no and off included. That is the class
#    0.10.9 removed from the MCP surface, where an unrecognised value for a
#    declared boolean is refused rather than coerced; the fixture-E finding there
#    was `draft` reading as CLEAR and publishing protected content while
#    returning ok:1. The pool conf is the one place an operator writes such a
#    value BY HAND, into a file, with no validation and no feedback.
#
# 2. Nothing reported whether the mode was active. X-Lazysite-Front exists only
#    in the SM283 proxy template, so on an instance without that template - which
#    is the instance the SM283 sweep is still pending on - the mode was
#    indistinguishable from its absence. A 0.10.9 field test took ten anonymous
#    samples either side of the upgrade, found nothing network noise could
#    resolve, and could not establish whether the feature was even switched on.
#
# WHY BOTH AT ONCE. Fixing the observability without the parser leaves a check
# faithfully reporting a value the operator did not intend; fixing the parser
# without the observability leaves them unable to confirm the outcome. Together
# an operator could write FRONT_DOOR=false, get front-door mode, and have no way
# to discover it - which is what made the setting unauditable rather than merely
# awkward.
#
# REFUSING IS THE POINT, and silently defaulting to off would be a second version
# of the same defect - a control doing something other than what was written and
# saying nothing. A pool that will not start is visible; one running in a mode
# nobody chose is not.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $pool = "$root/tools/lazysite-pool.pl";
my $chk  = "$root/tools/lazysite-check.pl";
ok( -f $pool, 'the pool launcher is present' );
ok( -f $chk,  'the check tool is present' );

# Drive the launcher's value parser without starting a pool. --instance names a
# conf that does not exist, so it bails early on that - EXCEPT when the value is
# bad, where it must bail on the VALUE instead. Which message comes back is the
# whole assertion.
sub launcher_says {
    my ($value) = @_;
    my $dir = tempdir( CLEANUP => 1 );
    local $ENV{FRONT_DOOR} = $value;
    local $ENV{DOCROOT}    = $dir;
    # USER names an account that does not exist. It is present and not root, so
    # it clears the two USER checks that precede the value check, and then the
    # launcher bails on getpwnam - the very next check, and before it creates
    # anything at all. So a BAD value bails on the value and a GOOD one bails on
    # the user, with no socket bound either way and nothing left behind.
    #
    # That ordering is also why the value check had to move up beside the other
    # configuration checks: validating it at the point of USE meant a bad value
    # went unreported until after the socket had been bound and chowned, and on
    # a host where the bind itself failed it was never reported at all.
    local $ENV{USER} = 'lazysite-no-such-user-for-a-test';
    my $out = qx($^X \Q$pool\E --instance no-such-pool-for-a-test 2>&1);
    return $out // '';
}

subtest 'an unrecognised FRONT_DOOR value is refused, naming it' => sub {
    for my $bad (qw(maybe enabled 2 yeah)) {
        my $out = launcher_says($bad);
        like( $out, qr/\Qnot a yes\/no value\E/,
            "FRONT_DOOR=$bad is refused rather than guessed at" );
        like( $out, qr/\Q$bad\E/, "and the message names the value: $bad" );
    }
};

subtest 'the conventional spellings are accepted on both sides' => sub {
    # These must NOT trip the value check - they reach the missing-conf bail
    # instead, which is what proves the parser let them through.
    for my $v (qw(1 true yes on 0 false no off TRUE Off)) {
        my $out = launcher_says($v);
        unlike( $out, qr/\Qnot a yes\/no value\E/,
            "FRONT_DOOR=$v is a recognised spelling" );
    }
};

# The two halves of the observability check that can be tested without a real
# /etc/lazysite/pools - the reporter reads that directory, which a test may not
# create. So assert the SOURCE says the right things: that it reads the pool
# conf on disk, matches on DOCROOT rather than the instance name, and reports
# all three states. A source assertion is weaker than an execution one and is
# said so here plainly rather than dressed up.
my $src = do { open my $fh, '<', $chk or die $!; local $/; <$fh> };

subtest 'the check reports front-door mode from the pool conf' => sub {
    like( $src, qr/sub report_front_door_mode/,
        'the reporter exists' );
    like( $src, qr/report_front_door_mode\(\);/,
        'and is actually called from run_checks - a reporter nobody calls is '
            . 'the defect this file exists to stop, one level up' );

    like( $src, qr{/etc/lazysite/pools},
        'it reads the pool configuration directory' );
    like( $src, qr/DOCROOT\\s\*=/,
        'and matches the conf to THIS docroot' );

    # Matching on the docroot rather than the instance name matters: the
    # instance name is conventionally the domain and nothing enforces it, so a
    # check keyed on the name could report another site's setting - worse than
    # reporting nothing.
    like( $src, qr/instance name is conventionally the domain/,
        'and records why it does not key on the instance name' );

    like( $src, qr/front-door mode is ON/,  'it reports the ON state' );
    like( $src, qr/front-door mode is OFF/, 'it reports the OFF state' );
    like( $src, qr/is not a yes\/no value/,
        'and reports a bad value as a FAIL, since the pool will not start' );
};

subtest 'a site with no pool conf is not nagged' => sub {
    # Plain CGI is a supported arrangement where front-door mode does not apply,
    # and a check that speaks on every healthy site is one people learn to
    # scroll past. That reasoning is load-bearing, so it is asserted rather than
    # left to a future reader to rediscover by deleting the guard.
    like( $src, qr/return unless -d \$dir/,
        'no pools configured: the reporter stays silent' );
    like( $src, qr/return unless defined \$mine/,
        'no conf for THIS docroot: the reporter stays silent' );
};

done_testing();
