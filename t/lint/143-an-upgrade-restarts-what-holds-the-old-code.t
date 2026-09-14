#!/usr/bin/perl
# N141-05: the Hestia deploy restarts every long-lived process that holds engine
# code, not just one of them.
#
# A FastCGI pool worker loads the engine once and serves many requests from it.
# An upgrade replaces the files on disk; the worker goes on running what it
# already has. Until this, the deploy restarted `lazysited@` (the persistent
# runtime, SM757) and never `lazysite@` (the pool) - and the only mention of a
# pool restart anywhere in the tree was one line of INSTALL-RUNBOOK.md telling a
# human to remember.
#
# HOW IT SURFACED, and why it looked like something else first. xisl.com and
# dhcf.eu reported `generator lazysite 0.13.13` on a 0.14.0 engine - including
# on a freshly rendered 404 for a path never requested, which rules out the page
# cache. It was filed as a version-reporting defect. It is not: the version was
# HONEST. Those pages really were rendered by 0.13.13, because that is the code
# the worker still held. The label was the only visible symptom of a site
# running a release nobody had installed on it.
#
# The second consequence outlives the label: `_lazysite_version()` is also the
# `?v=` asset cache-buster, so a stale worker pins it - the mechanism that exists
# to force browsers to refetch chrome stops moving at exactly the upgrade it is
# there for.
#
# WHY A SOURCE CHECK. Driving it needs systemd, a pool, and a real upgrade.
# The behaviour is a guarded restart in a shell script, and t/lint/37 already
# reads these scripts by the same method.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root   = repo_root();
my $deploy = "$root/installers/hestia/lazysite-hestia-deploy.sh";

open my $fh, '<', $deploy or BAIL_OUT("no deploy script: $!");
my $src = do { local $/; <$fh> };
close $fh;

# Comments quote unit names to explain them; the check is about what RUNS.
( my $code = $src ) =~ s/^\s*#.*$//mg;

# --- both long-lived holders are restarted -----------------------------------
like( $code, qr/systemctl restart "lazysited\@\$DOMAIN\.service"/,
    'the persistent runtime is restarted on upgrade (SM757, unchanged)' );

like( $code, qr/systemctl restart "lazysite\@\$DOMAIN\.service"/,
    'and so is the FastCGI pool, which holds the engine it started with' )
    or diag( 'Without this a pooled site serves the OLD ENGINE after an upgrade '
        . 'that reported success, and its ?v= asset cache-buster freezes with '
        . 'it. The only restart used to live in INSTALL-RUNBOOK.md as a '
        . 'sentence asking somebody to remember.' );

# --- and only when there is something to restart -----------------------------
#
# A site not using the pool must be untouched and silent: an unconditional
# restart would print a failure on every ordinary CGI site and teach operators
# to ignore the output.
like( $code, qr/is-active --quiet "lazysite\@\$DOMAIN\.service"/,
    'the pool is restarted only when it is actually running' )
    or diag( 'An unconditional restart noisily fails on every site that does '
        . 'not use the pool, which is most of them.' );

# --- the runbook no longer presents it as the operator's job to remember -----
my $runbook = do {
    open my $r, '<', "$root/installers/hestia/INSTALL-RUNBOOK.md" or die $!;
    local $/;
    <$r>;
};
like( $runbook, qr/deploy \*\*now does that for you\*\*/,
    'the runbook says the deploy handles it' )
    or diag( 'Leaving the old wording means an operator reads a manual step '
        . 'that has been automated, and either does it twice or distrusts the '
        . 'automation.' );

done_testing();
