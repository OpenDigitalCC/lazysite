#!/usr/bin/perl
# SM302: re-run a review's mechanical findings against the current tree.
#
# WHY THIS EXISTS. Every eight-dimension review opens by verifying the previous
# review's findings as fixed or open rather than assuming. That discipline is
# correct and it was entirely manual: the assessor read last time's prose and
# worked out, per finding, what would prove it. Across two reviews that was
# roughly thirty checks, run interactively as one-off greps, written down
# nowhere.
#
# A finding whose check is reinvented is a finding that can be re-checked
# DIFFERENTLY - or silently not at all.
#
# THE THREE-STATE RESULT IS THE POINT. A check that could not RUN is not a
# check that passed, and this whole release line is a catalogue of controls that
# reported success without doing the work. So the verdicts are:
#
#   fixed        the check ran and the finding no longer holds
#   still-open   the check ran and the finding holds
#   COULD NOT    the check could not be run - a missing file, a bad expression,
#                a command that is not installed. Never counted as either.
#
# and a finding with no `verify` is reported as not-mechanical rather than
# omitted, because "we did not automate this one" is a fact the next reviewer
# needs and an absence is not.
#
# Usage: tools/lazysite-review-verify.pl <review-dir> [--quiet]
use strict;
use warnings;
use JSON::PP       ();
use Cwd            ();
use File::Basename ();

BEGIN {
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
}

my $dir   = shift @ARGV;
my $quiet = grep { $_ eq '--quiet' } @ARGV;

unless ( defined $dir && -d $dir ) {
    print {*STDERR} "usage: lazysite-review-verify.pl <review-dir> [--quiet]\n";
    exit 2;
}

my $file = "$dir/findings.json";
unless ( -f $file ) {
    print {*STDERR} "review-verify: no findings.json in $dir\n";
    print {*STDERR} "review-verify: a review without one cannot be re-checked,\n";
    print {*STDERR} "review-verify: which is the state SM302 was filed about.\n";
    exit 2;
}

my $json = do {
    open my $fh, '<', $file or die "$file: $!";
    local $/;
    <$fh>;
};
my $doc = eval { JSON::PP->new->decode($json) };
unless ( ref $doc eq 'HASH' && ref $doc->{findings} eq 'ARRAY' ) {
    print {*STDERR} "review-verify: $file is not a findings document"
        . ( $@ ? ": $@" : " (expected { findings: [...] })\n" );
    exit 2;
}

# The repo root: the tree the checks are asked about. Taken from the tool's own
# location rather than the cwd, so a check that greps a relative path means the
# same thing wherever it is run from.
my $root = File::Basename::dirname( File::Basename::dirname( Cwd::abs_path(__FILE__) ) );

my ( @fixed, @open_, @unrunnable, @manual );

for my $f ( @{ $doc->{findings} } ) {
    my $id    = $f->{id}    // '(no id)';
    my $title = $f->{title} // '';

    unless ( defined $f->{verify} && length $f->{verify} ) {
        push @manual, [ $id, $title ];
        next;
    }

    # The expression is shell, run with the repo root as cwd. It is a check
    # written by whoever wrote the review, in the project's own tree - the same
    # trust boundary as any other tool here.
    my $out = `cd \Q$root\E && ( $f->{verify} ) 2>&1`;
    my $rc  = $? >> 8;
    my $sig = $? & 127;

    # A command that could not be found exits 127, and a shell that died on a
    # signal reports one. Neither is "the finding is still open" - it is "this
    # check did not happen", and conflating them is the defect this tool is
    # about.
    if ( $sig || $rc == 127 ) {
        push @unrunnable, [ $id, $title, ( $sig ? "signal $sig" : 'command not found' ), $out ];
        next;
    }

    # Convention: the expression is TRUE (exit 0) when the finding is FIXED.
    # Stated here because the opposite convention is equally natural and a
    # reviewer who assumes the wrong one gets every verdict backwards.
    if ( $rc == 0 ) { push @fixed, [ $id, $title ] }
    else            { push @open_, [ $id, $title, $out ] }
}

sub show {
    my ( $label, $rows, $with_output ) = @_;
    return unless @$rows;
    printf "%s (%d)\n", $label, scalar @$rows;
    for my $r (@$rows) {
        printf "  %-8s %s\n", $r->[0], $r->[1];
        if ( $with_output && defined $r->[-1] && length $r->[-1] && !$quiet ) {
            my $o = $r->[-1];
            $o =~ s/\s+\z//;
            $o =~ s/^/           /mg;
            print "$o\n" if length $o;
        }
    }
    print "\n";
}

print "review-verify: $dir\n\n";
show( 'FIXED',                             \@fixed,      0 );
show( 'STILL OPEN',                        \@open_,      1 );
show( 'COULD NOT BE CHECKED',              \@unrunnable, 1 );
show( 'NOT MECHANICAL - re-check by hand', \@manual,     0 );

printf "%d fixed, %d still open, %d could not be checked, %d not mechanical\n",
    scalar @fixed, scalar @open_, scalar @unrunnable, scalar @manual;

# EXIT CODE. Unrunnable is a failure, not a pass: a review whose checks cannot
# run has told the next reviewer nothing, and exiting 0 on it would recreate by
# hand the exact thing this tool removes.
exit( @unrunnable ? 2 : @open_ ? 1 : 0 );
