#!/usr/bin/perl
# N142A: `lazysite upgrade` makes an upgraded site RUN the code it was upgraded
# to - and where it cannot, it says so.
#
# N141-05 fixed this for installers/hestia/lazysite-hestia-deploy.sh and stopped
# there. That was the wrong place to stop: INSTALL-RUNBOOK.md marks that script
# SUPERSEDED by the packages, so the path a modern site actually takes is
# `lazysite upgrade`, and it called no systemctl at all. The fix landed in a
# script the live flow does not run.
#
# It surfaced the way these things do: after 0.14.1 deployed, the site agent
# asked the operator to restart the daemon by hand, and the operator asked why
# the updater had not.
#
# WHY THE PACKAGE IS RIGHT NOT TO DO IT. debian/lazysite-common.postinst says:
# "It does NOT restart instances - which sites restart, and when, is the
# operator's call... a package upgrade must not take a fleet's runtimes down at
# once." That is about a FLEET-WIDE operation. `upgrade` is PER-SITE, and
# restarting the worker of the site just upgraded is the narrowest action
# available - which is the argument N141-05 made, applied where it bites.
#
# BOTH UNITS, because both hold engine code between requests: `lazysited@` (the
# persistent runtime, SM757) and `lazysite@` (the FastCGI pool).
#
# HOW THIS IS DRIVEN, AND WHAT THAT COSTS. This is a SOURCE check, not a
# behavioural one. Driving it for real needs systemd, root, a registered site
# and live units, and the suite has none of those - the same reason t/lint/143
# reads lazysite-hestia-deploy.sh rather than running it.
#
# So it asserts the DECISION - which units, under what condition, called from
# where - and cannot prove a restart happens on a real host. That gap is the
# honest limit of this file: if the units are ever renamed, or the call is moved
# behind a condition that is never true, these assertions would still pass. The
# field check is the one in the 0.14.1 test plan - the `generator` tag on a
# freshly rendered 404 after an upgrade - and it is the one that actually
# settles it.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $cli = repo_root() . '/tools/lazysite-cli.pl';
plan skip_all => "no $cli" unless -f $cli;

# --- the decision, read from the source --------------------------------------
#
# Asserted first and separately: if the sub is not there at all, every
# behavioural assertion below would pass vacuously against a stub.
my $src = do {
    open my $fh, '<', $cli or die $!;
    local $/;
    <$fh>;
};
( my $code = $src ) =~ s/^\s*#.*$//mg;

like( $code, qr/sub _restart_site_workers/,
    'the upgrade path has a restart step at all' );

like( $code, qr/lazysited\\\@\$domain\.service/,
    'it restarts the persistent runtime' );
like( $code, qr/lazysite\\\@\$domain\.service/,
    'and the FastCGI pool - both hold engine code between requests' )
    or diag( 'A pooled worker loads the engine once and serves many requests '
        . 'from it. Without this, an upgrade replaces the files and the worker '
        . 'goes on running what it already had.' );

like( $code, qr/is-active/,
    'and only when the unit is actually running' )
    or diag( 'An unconditional restart fails noisily on every ordinary CGI '
        . 'site, which is most of them, and teaches operators to skip the '
        . 'output.' );

# --- it is wired into the fleet path, not merely defined ---------------------
like( $code, qr/_restart_site_workers\( \$s->\{name\} \)/,
    'the --all path calls it for each site it upgraded' )
    or diag( 'A helper nothing calls is the same as no helper. N141-05 was '
        . 'real code in a script the live flow does not run.' );

like( $code, qr/\$is_root \? _restart_site_workers/,
    'and only as root, because a systemd unit is a system service' );

# --- the single-site path cannot, and says so --------------------------------
#
# `upgrade --docroot` refuses root (refuse_root), and restarting needs it. So
# the one thing it cannot do is the thing that decides whether the upgrade takes
# effect. Silence there is what left two sites serving a previous engine after
# an upgrade that reported success.
like( $code, qr/serving the PREVIOUS engine/,
    'the single-site path tells the operator what is still needed' )
    or diag( 'It cannot restart - it refuses root by design - so the honest '
        . 'thing is to name the command rather than leave it unsaid.' );

like( $code, qr/systemctl restart \$_/,
    'and names the exact command' );

# --- the reminder is conditional ---------------------------------------------
#
# A site with no units must be told nothing: a reminder that never applies is
# one people learn to skip, which is how the runbook's own restart line came to
# be ignored for four releases.
# SM892 moved this into `_say_what_needs_restarting`, shared with the new
# `reinstall` verb - which replaces the same files, so a worker holding the old
# code in memory has the same problem whichever verb put the new code there.
#
# The assertion moved with it, and stopped pinning ONE expression. It used to
# match `@live && _domain_for_docroot`, which was how the guard happened to be
# spelled when both conditions sat in a single `if`; the extraction made them
# two early returns and the property did not change at all. What is asserted
# now is the property: both conditions are guards, and neither prints.
my ($restart_sub) = $code =~ /(sub _say_what_needs_restarting\b.*?\n\})/s;
ok( $restart_sub, 'the restart notice lives in one place' );
like( $restart_sub, qr/return unless length \$domain/,
    'an unregistered docroot is told nothing - there is no unit to name' );
like( $restart_sub, qr/return unless \@live/,
    'and a site with no RUNNING unit is told nothing either' )
    or diag( 'A reminder that never applies is one people learn to skip, '
        . "which is how the runbook's own restart line came to be ignored "
        . 'for four releases.' );

done_testing();
