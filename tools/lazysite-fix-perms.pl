#!/usr/bin/perl
# lazysite-fix-perms - SM215: repair ownership/mode drift under a site's lazysite/
# tree (e.g. after a credential reset or install run under sudo left files
# root-owned that the www-data CGI cannot access, or a directory that lost its
# group-write bit).
#
# This is a friendly, single-purpose front-end to `lazysite-check --fix`, which is
# the canonical, tested repairer: it applies the chmod fixes always and the chown
# fixes when run as root, using a handover mode that preserves the CGI's access
# across an ownership change, then re-runs every check so the printed report
# reflects the post-fix state. Keeping ONE implementation avoids the two drifting
# apart (and lets this tool inherit check's more careful chown handover).
#
#   lazysite-fix-perms --docroot DIR            # DRY-RUN: report what would change
#   lazysite-fix-perms --docroot DIR --apply    # repair (run as root to fix ownership)
#   ... [--cgibin DIR] [--owner USER] [--group GROUP]
#
# Standalone + module-free; no network. Exec's lazysite-check.pl (installed
# beside it under tools/); its exit code is this tool's exit code.
use strict;
use warnings;
use File::Basename qw(dirname);

my ( @pass, $apply, $docroot );
while (@ARGV) {
    my $a = shift @ARGV;
    if    ( $a eq '--apply' ) { $apply = 1 }
    elsif ( $a eq '--help' )  { print _usage(); exit 0 }
    elsif ( $a eq '--docroot' ) { $docroot = shift @ARGV; push @pass, '--docroot', $docroot }
    elsif ( $a eq '--cgibin' || $a eq '--owner' || $a eq '--group' ) {
        push @pass, $a, shift @ARGV;
    }
    else { die "Unknown argument '$a'\n" . _usage() }
}
sub _usage {
    return
        "Usage: lazysite-fix-perms --docroot DIR [--apply] [--cgibin DIR] [--owner USER] [--group GROUP]\n"
        . "Repairs ownership/mode drift under lazysite/ by delegating to "
        . "'lazysite-check --fix' (the canonical repairer). Dry-run without --apply.\n";
}
die "--docroot is required\n" . _usage() unless defined $docroot && length $docroot;

# SM624: this tool works and is not being retired - it is the SINGLE-SITE door,
# and `lazysite repair` is the one that also addresses a fleet. An operator who
# found this one first had no way to know the other existed, which is how four
# different invocations ended up in use for one job. Say it once, on stderr, so
# it never pollutes output a script is parsing.
print {*STDERR} "note: `lazysite repair --domain <site>` does this and re-checks "
    . "afterwards; `--all` does every site.\n"
    unless $ENV{LAZYSITE_QUIET_HINTS};

my $check = dirname(__FILE__) . '/lazysite-check.pl';
die "cannot find lazysite-check.pl beside this tool ($check)\n" unless -f $check;

push @pass, '--fix' if $apply;
print STDERR $apply
    ? "lazysite-fix-perms: repairing via 'lazysite-check --fix' ...\n"
    : "lazysite-fix-perms: DRY-RUN via 'lazysite-check' (pass --apply to repair) ...\n";
exec $^X, $check, @pass;
die "could not run lazysite-check: $!\n";
