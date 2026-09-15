#!/usr/bin/perl
# SM864: every users-tool command named in a shipped installer, README or runbook
# is one the tool actually dispatches.
#
# SM659 renamed `setup-manager` to `setup-sysop` and deliberately kept no alias.
# It updated installers/hestia/INSTALL-RUNBOOK.md and missed two other readers:
# lazysite-hestia-deploy.sh, which CALLED the dead verb on every fresh install,
# and debian/lazysite-hestia.README.Debian, which told operators to type it.
#
# The runbook being right is what hid it. A reader who checked one place found
# the current name and stopped - which is the shape this project keeps closing:
# a rename lands wherever the author was looking and survives everywhere else
# (feedback_a_declaration_the_code_ignores - find every reader).
#
# THE TOOL ITSELF IS NOT AT FAULT and this check does not pretend otherwise: it
# answers an unknown command with usage and exit 2, correctly. What failed was
# a caller that discarded that status, and a document nobody re-read. So this
# tests the DOCUMENTS AND SCRIPTS against the dispatcher, not the dispatcher.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or return undef;
    local $/;
    return <$fh>;
}

# --- what the tool actually dispatches --------------------------------------
#
# Read from the ladder, never from a second list: the whole point is that a
# hand-kept copy is what drifts.
my $tool = slurp("$root/tools/lazysite-users.pl");
ok( $tool, 'the users tool is readable' ) or do { done_testing(); exit };

my %DISPATCHED;
while ( $tool =~ /\$cmd\s+eq\s+'([a-z][a-z0-9-]*)'/g ) { $DISPATCHED{$1} = 1 }
cmp_ok( scalar keys %DISPATCHED, '>=', 30,
    'the dispatcher was parsed (30+ commands found)' )
    or diag( 'If this drops, the ladder changed shape and the regex below no '
        . 'longer finds commands - which would make every assertion in this '
        . 'file vacuous rather than passing.' );

# --- the readers that name commands to an operator ---------------------------
#
# SM872: THIS WAS A HAND-PICKED LIST OF SEVEN, in a check whose first line says
# "every reader". 102 shipped files name the users tool, and the list named the
# seven the author of SM864 happened to be looking at - so `tools/lazysite-check.pl`,
# which printed the dead verb in FOUR operator-facing remedies, sailed through a
# check written to catch exactly that. The same failure the file's own header
# describes, committed by the file itself.
#
# So the default is now inverted: every tracked file is a reader unless it is
# somewhere the project RECORDS HISTORY, where naming a retired verb is correct
# and removing it would falsify the record. That list is short, explicit, and
# the only thing a future author has to think about.
my @EXEMPT = (
    qr{^CHANGELOG\.md$},           # dated entries describe the release they shipped in
    qr{^docs/review/},             # eight-dimension snapshots, true as at their date
    qr{^docs/feature-requests/},   # filings ABOUT a rename must quote the old name
);

my @READERS = grep {
    my $rel = $_;
    !( grep { $rel =~ $_ } @EXEMPT )
} tracked_files();

sub tracked_files {
    my @out;
    open my $ls, '-|', 'git', '-C', $root, 'ls-files' or return ();
    while ( my $l = <$ls> ) {
        chomp $l;
        next if $l =~ m{^(?:t/|tmp/)};
        push @out, $l;
    }
    close $ls;
    return @out;
}

# Commands that were REMOVED and must not be named as though they work. Kept as
# an explicit list rather than "anything not dispatched", because prose legitimately
# mentions a retired name while explaining the change - only an INSTRUCTION to run
# one is a defect, and an explicit list is what lets this check say which is which.
my %RETIRED = ( 'setup-manager' => 'SM659 renamed it to setup-sysop, with no alias' );

# SM659 R2 (0.14.3): THE POD OF ANY TOOL, WHEREVER THE NAME SITS ON THE PAGE.
#
# N141B-G found the users tool's own manual still saying "C<setup-manager> - one
# command to create the manager account" four releases after the dispatcher
# stopped accepting it - the one page an operator reads BEFORE their first
# successful command. t/lint/144 now guards that file's POD, and it does it
# well; this file did not, and a sabotage confirms why: the proximity rule below
# wants the tool's name within 120 characters of the dead verb, and a manual
# names its own tool once at the top and then never again. So the same mistake
# in ANY OTHER tool's POD is still caught by nothing.
#
# PROSE ABOUT A RENAME IS NOT A DEFECT, and the excuse is the one t/lint/144
# uses, deliberately the same rule in the same words: "renamed from
# C<setup-manager>, no alias" is the most useful sentence on the page for
# somebody holding an old runbook.
sub pod_text {
    my ($src) = @_;
    my ( $out, $in ) = ( '', 0 );
    for my $l ( split /\n/, $src ) {
        if    ( $l =~ /^=cut\b/ ) { $in = 0; next }
        elsif ( $l =~ /^=[a-z]/ ) { $in = 1 }
        $out .= "$l\n" if $in;
    }
    return $out;
}

my $checked  = 0;
my $with_pod = 0;
for my $rel (@READERS) {
    my $src = slurp("$root/$rel");
    next unless defined $src;

    # Only files that NAME the tool can instruct anyone to run one of its
    # commands. Skipping the rest keeps the assertion count meaningful instead
    # of asserting the obvious about several hundred unrelated files.
    next unless $src =~ /lazysite-users\.pl|lazysite users/;
    $checked++;

    for my $dead ( sort keys %RETIRED ) {
        # An instruction to RUN it: the name near the tool, or near the
        # `lazysite users` wrapper. A sentence ABOUT the rename is not matched,
        # and should not be.
        #
        # SM872: NOT LINE BY LINE. lazysite-manager-api.pl:341 builds the
        # user-facing "this site has no manager account yet" message by
        # concatenating over three lines, putting `lazysite-users.pl` on one and
        # `setup-manager` on the next - so a per-line grep saw two innocent lines
        # and missed the single worst instance in the tree: an error message
        # shown to the operator of a fresh install, naming a command that exits 2.
        # Newlines, comment markers and string quotes are flattened out before
        # matching. NOT the full stop: `.` is inside `lazysite-users.pl`, and
        # stripping it made the first draft of this match nothing at all - a
        # check that passes by finding nothing is worse than the gap it replaced.
        ( my $flat = $src ) =~ s/[\n\r]+/ /g;
        $flat =~ s/\s*(?:^|\s)#\s*/ /g;
        $flat =~ s/['"]\s*[.,]?\s*['"]?/ /g;
        $flat =~ s/\s+/ /g;
        my @bad;
        push @bad, $1
            while $flat
            =~ /((?:lazysite-users\.pl|lazysite users).{0,120}?\b\Q$dead\E\b)/gs;
        is( scalar @bad, 0, "$rel does not tell anyone to run '$dead'" )
            or diag( "$RETIRED{$dead}\n  " . join( "\n  ", @bad ) );

        my $pod = pod_text($src);
        next unless length $pod;
        $with_pod++ if $dead eq ( sort keys %RETIRED )[0];
        my @pod_bad;
        while ( $pod =~ /\b\Q$dead\E\b/g ) {
            my $at   = $-[0];
            my $from = $at < 200 ? 0 : $at - 200;
            my $near = substr $pod, $from, 400;
            next if $near =~ /\b(?:renamed|removed|no alias|does not exist|retired)\b/i;
            ( my $line = substr $pod, $at < 60 ? 0 : $at - 60, 140 ) =~ s/\s+/ /g;
            push @pod_bad, $line;
        }
        is( scalar @pod_bad, 0, "$rel: its POD does not present '$dead' as a command" )
            or diag( "$RETIRED{$dead}\n  "
                . join( "\n  ", @pod_bad )
                . "\n\nA manual is what an operator reads BEFORE their first "
                . "successful command. Say the name is gone and what replaced "
                . "it - the words 'renamed', 'removed', 'no alias', 'retired' "
                . "in the same paragraph are what tells this check the "
                . "sentence is history rather than instruction." );
    }
}

cmp_ok( $with_pod, '>=', 3, 'files with POD were among those scanned' )
    or diag( 'The POD extraction found nothing to read, which would make every '
        . 'POD assertion above pass by examining an empty string.' );

# The floor that stops this going vacuous. It is a FLOOR, not the count: files
# come and go. If it trips, the discovery broke (git ls-files empty, the tree
# moved) - which would make every assertion above pass by finding nothing.
cmp_ok( $checked, '>=', 30, 'the shipped files naming the users tool were discovered' )
    or diag( "Only $checked files were scanned. At the time this was written 49 "
        . 'tracked files named the tool outside the historical record (102 '
        . 'including it). A number far below that means discovery failed, not '
        . 'that the tree shrank.' );

# And the current name really is dispatched, so the advice these files now give
# is advice that works.
ok( $DISPATCHED{'setup-sysop'}, 'setup-sysop is dispatched' );
ok( !$DISPATCHED{'setup-manager'},
    'setup-manager is not - so naming it anywhere is naming nothing' );

done_testing();
