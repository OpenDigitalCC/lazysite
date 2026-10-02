#!/usr/bin/perl
#
# SM933 PR1 (A4): AN INSTALL EITHER SAYS IT IS HEALTHY OR NAMES ITS OWN FAULT.
#
# From the field, 2026-10-02. A fresh provision on a Hestia domain printed
# `Installed: 265`, `Overwrote: 0` and four Next steps, and every request to the
# site answered 500 Internal Server Error. The engine compiled cleanly. The fault
# was ownership and modes that provision itself had just written, and
# lazysite-check.pl could see all of it - it was simply never run, because
# running it was a separate thing an operator had to remember after the install
# said it was done.
#
# WHAT THIS PINS, AND WHY EACH HALF MATTERS. A gate that only checked the happy
# path would pass if the check were wired in and its verdict thrown away, which
# is the defect in a different costume. So both directions are asserted:
#
#   1. a healthy install reports health POSITIVELY and exits 0 - because "said
#      nothing" and "said it was fine" must not read the same way;
#   2. an install whose tree carries a real fault exits 4 and NAMES the path -
#      the exit code is what a wrapper script reads, and the path is what the
#      person reads;
#   3. exit 4 and not 3, because --channel-check already means something by 3;
#   4. the report arrives AFTER the summary, so an operator who stops reading at
#      "Installed: 265" is the person this is written for.
#
# The fault used in (2) is a docroot content directory stripped of group write.
# NOT lazysite/cache: the runtime-paths pass re-applies that mode on every run,
# so the installer repairs it before the check ever sees it - which made the
# first version of this test pass for the wrong reason.
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_manifest_guard site_tempdir);

my $ROOT    = "$FindBin::Bin/../..";
my $INSTALL = "$ROOT/install.pl";

plan skip_all => 'install.pl not found' unless -f $INSTALL;

my $MF_GUARD = repo_manifest_guard();

# The fixture's group, not the web server's - see t/tools/35 and 04-check.t.
my $FIXTURE_GROUP = getgrgid( $) + 0 ) // ( $) + 0 );

# site_tempdir, not a bare tempdir: the engine resolves its tree BESIDE the
# docroot as well as inside it, so a docroot that IS the tempdir root gives the
# resolver nowhere to look and the fixture stops resembling a site (lint 118).
my $docroot = site_tempdir();
my $cgibin  = "$docroot/../cgi-bin";
make_path($cgibin);

# `provision` REFUSES on a tree that already carries an install - it names
# upgrade/reinstall instead - so the second pass below must ask for `reinstall`.
# The first version of this file called provision twice and the second call never
# ran at all, which made the fault-direction subtest fail for its own reason
# rather than the one under test.
sub install {
    my ($mode) = @_;
    my $out = `$^X \Q$INSTALL\E --mode \Q$mode\E --docroot \Q$docroot\E \\
        --cgibin \Q$cgibin\E --serving-group \Q$FIXTURE_GROUP\E 2>&1`;
    return ( $out, $? >> 8 );
}

my ( $clean_out, $clean_rc ) = install('provision');

subtest 'a healthy install says so, positively, and exits 0' => sub {
    is( $clean_rc, 0, 'exit 0' ) or diag $clean_out;
    like( $clean_out, qr/=== Health check ===/,
        'the check ran as part of the install' );
    like( $clean_out, qr/passed its own health check/,
        'and said so in words - silence would be indistinguishable from "not run"' );
    like( $clean_out, qr/0 failure\(s\)/, 'with the count' );
};

subtest 'the verdict comes after the summary the operator stops reading at' => sub {
    my $summary = index( $clean_out, 'Install summary' );
    my $health  = index( $clean_out, '=== Health check ===' );
    cmp_ok( $summary, '>=', 0, 'the summary is printed' );
    cmp_ok( $health,  '>',  $summary,
        'and the health verdict comes after it, where a reader who stopped at '
            . '"Installed: 265" will still meet it' );
};

subtest 'a real fault exits 4 and names the path' => sub {
    # The reported shape: a content directory the CGI can no longer write.
    chmod 02755, "$docroot/docs" or plan skip_all => "cannot chmod $docroot/docs";
    my ( $out, $rc ) = install('reinstall');

    is( $rc, 4, 'exit 4 - installed, and NOT serviceable' ) or diag $out;
    isnt( $rc, 3, 'not 3, which --channel-check already means' );
    isnt( $rc, 0, 'and emphatically not 0, which is the reported defect' );
    like( $out, qr/docs is 2755 and is NOT group-writable/,
        'the report names the path and the mode' );
    like( $out, qr/THE SITE IS NOT SERVICEABLE YET/,
        'and the installer says plainly that the site is not usable yet' );
    like( $out, qr/lazysite check --docroot \S+ --fix/,
        'with the repair one paste away' );

    # Put it back so a later run of this file starts from a healthy tree.
    chmod 02775, "$docroot/docs";
};

subtest 'the health check is skippable only by absence, and absence is reported'
    => sub {
    # A payload that predates the tool must not read as a healthy site. There is
    # no flag for this on purpose - the only way to not get a verdict is for the
    # tool to be missing, and that is reported as SKIPPED rather than passed.
    my $help = `$^X \Q$INSTALL\E --help 2>&1`;
    unlike( $help, qr/--no-health-check|--skip-health/,
        'no flag exists to silence the verdict' );
    like( $help, qr/--serving-group/,
        'the serving group is documented, because the verdict depends on it' );
    like( $help, qr/^\s*4\s+installed, and the site is NOT serviceable/m,
        'and exit 4 is documented as its own outcome' );
};

done_testing();
