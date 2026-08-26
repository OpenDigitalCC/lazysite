#!/usr/bin/perl
# SM624: four invocations were in field use for one job, because the verb built
# for it is undocumented.
#
# The operator, repairing 31 sites after an upgrade, had used all of these:
#   /tmp/lazysite-postupgrade.sh --check     (an ad-hoc script)
#   tools/lazysite-fix-perms.pl              (single-site front-end)
#   tools/lazysite-cli.pl check --fix        (the REPORTING verb, with a flag)
#   sudo perl .../lazysite-check.pl --fix    (the engine, in a shell loop)
#
# None of them disagree - they are one implementation behind four entrances, and
# lazysite-fix-perms says so in its own header. The problem is that `lazysite
# repair` exists, does the job properly (fix, then RE-CHECK and report the state
# after), addresses a fleet with --all, and appears NOWHERE in OPERATOR.md. An
# operator who found any other door first had no way to learn of it.
#
# So this test is about the DOC, not the code: the code was already right.
use strict;
use warnings;
use Test::More;
use FindBin;

my $root = "$FindBin::Bin/../../..";
my $doc  = "$root/docs/OPERATOR.md";
my $cli  = "$root/tools/lazysite-cli.pl";
plan skip_all => "no $doc" unless -f $doc;

my $d = do { open my $fh, '<', $doc or die $!; local $/; <$fh> };
my $c = do { open my $fh, '<', $cli or die $!; local $/; <$fh> };

# --- 1. the verb the operator should use is documented ----------------------
like( $d, qr/lazysite repair/, 'OPERATOR.md names `lazysite repair`' );
like( $d, qr/repair --all/,    'and the fleet form' );
like( $d, qr/--dry-run/,       'and the preview, so a fleet run can be looked at first' );

# --- 2. it says the fleet form works WITHOUT the deb registry ---------------
# The reason this matters: /etc/lazysite/sites.d is written by `provision`,
# which the deb path runs and the tarball path never does. An operator on the
# deployment shape this project actually uses would otherwise read "--all walks
# the registry" and conclude it cannot help them.
# Asserted on the SUBSTANCE, not on a word. The first version of this matched
# /Hestia|registry does not exist|tarball/ and a sabotage removed the caveat
# entirely while "tarball" survived in a different sentence three lines down -
# so the assertion passed on a doc that no longer told the operator the thing
# that matters to them.
like( $d, qr/falling back to Hestia's own site list/,
    'and that the fleet form falls back to Hestia discovery' );
like( $d, qr/`provision` is what\s*
?writes the registry and the tarball path never runs it/,
    'saying WHY the registry is empty on this deployment shape' );
like( $d, qr{tools/lazysite-cli\.pl repair},
    'with the invocation for a host that has no /usr/bin/lazysite' );

# --- 3. the other doors are named, so finding one is not a dead end ---------
# Naming them is the point. An operator who lands on fix-perms should learn the
# fleet verb exists rather than build a shell loop, which is what happened.
like( $d, qr/lazysite-fix-perms/, 'the single-site front-end is acknowledged' );
like( $d, qr/lazysite-check\.pl/, 'and the engine underneath' );
like( $d, qr/check.*REPORTS|check.*reports/,
    'and the difference between the reporting verb and the repairing one' );

# --- 4. troubleshooting points at the verb, not at hand-chmod ---------------
# Two rows told the operator to chmod by hand or re-deploy, for exactly the
# symptoms repair exists to fix.
{
    my ($tbl) = $d =~ /## Troubleshooting(.*?)(?=\n## )/s;
    ok( $tbl, 'the troubleshooting table is present' );
    unlike( $tbl, qr/chmod g\+w/,
        'no row tells the operator to chmod by hand' );
    my @perm_rows = grep { /Permission denied|not writable/ } split /\n/, ( $tbl // '' );
    ok( scalar @perm_rows, 'there are permission rows to check' );
    is_deeply( [ grep { !/lazysite repair/ } @perm_rows ], [],
        'every permission symptom points at `lazysite repair`' )
        or diag( join "\n", @perm_rows );
}

# --- 5. the CLI really has the verb the doc promises -------------------------
# A doc naming a verb the tool does not have is worse than no doc. Checked
# against the CLI rather than trusted.
like( $c, qr/\$verb eq 'repair'/, 'the CLI implements the repair verb' );
like( $c, qr/repair --docroot D \| --domain NAME \| --all/,
    'and its own usage offers --all' );

# --- 6. the redundant door signposts the main one ---------------------------
# RUN it. The first version of this grepped the source for /lazysite repair/ and
# a sabotage deleted the print statement outright while the assertion still
# passed - because the COMMENT above the print says the same words. A tool's
# source containing a string is not the tool saying it.
SKIP: {
    my $fp = "$root/tools/lazysite-fix-perms.pl";
    skip 'no fix-perms', 3 unless -f $fp;
    require File::Temp;
    my $d = File::Temp::tempdir( CLEANUP => 1 );
    mkdir "$d/lazysite";

    my $err = "$d/err";
    my $rc  = system("$^X \Q$fp\E --docroot \Q$d\E >/dev/null 2>\Q$err\E");
    my $e   = do { open my $fh, '<', $err or die $!; local $/; <$fh> // '' };

    like( $e, qr/lazysite repair/,
        'running fix-perms actually PRINTS the pointer to the fleet verb' );
    like( $e, qr/--all/, 'including the fleet form' );

    # On stderr specifically: stdout is what a script parses.
    my $out = `$^X \Q$fp\E --docroot \Q$d\E 2>/dev/null`;
    unlike( $out, qr/lazysite repair/,
        'and not on stdout, where it would corrupt parsed output' );
}

done_testing();
