#!/usr/bin/perl
# tools/tracked-tree-check.pl - did the suite leave a tracked file edited?
#
# SM894 M3. Three tests edit tracked files (VERSION, SIGNOFF.md, RELIABILITY.md,
# the practice briefing) and restore them on the way out. A run that does not
# finish - an interrupted prove, a gate timeout, an OOM kill - leaves them
# edited, and nothing noticed: the cost arrived later, as t/lint/63 failing on
# a tree nobody had touched, and the next person debugged the lint.
#
# This asks the question at the moment it can be answered. Run after the suite
# (handoff.sh does), it lists every TRACKED file the working tree now differs
# on, and every backup TestHelper::preserve_tracked left behind - whose marker
# names the test that took it, which is the thing a reader wants to know.
#
#   perl tools/tracked-tree-check.pl [ROOT] [--preserve-dir DIR]
#
# Exit 0 when the tree is clean and no backup survived; 1 otherwise, with the
# files named. Untracked files are ignored: tmp/, logs and build artefacts are
# the suite's business.
use strict;
use warnings;
use Getopt::Long ();

my $preserve_dir;
Getopt::Long::GetOptions( 'preserve-dir=s' => \$preserve_dir ) or exit 2;
my $root = shift @ARGV // '.';
$preserve_dir //= "$root/tmp/preserve";

my @modified;
if ( open my $st, '-|', 'git', '-C', $root, 'status', '--porcelain', '--untracked-files=no' ) {
    while ( my $l = <$st> ) {
        chomp $l;
        next unless length $l;
        push @modified, substr( $l, 3 );
    }
    close $st;
}

my @left;
for my $marker ( sort glob("$preserve_dir/*.owner") ) {
    open my $fh, '<', $marker or next;
    chomp( my $test = <$fh> // '?' );
    chomp( my $path = <$fh> // '?' );
    close $fh;
    push @left, { test => $test, path => $path };
}

exit 0 unless @modified || @left;

print "tracked-tree-check: the suite left the working tree changed\n";
print "  modified tracked file: $_\n" for @modified;
for my $l (@left) {
    print "  backup never restored: $l->{path}\n      taken by $l->{test}\n";
}
print "  A test that edits a tracked file restores it through preserve_tracked (t/lib/TestHelper.pm);\n"
    . "  a backup that outlived its test means the test was killed before it could. Put the file\n"
    . "  back (git checkout -- FILE) and remove the backup under $preserve_dir.\n";
exit 1;
