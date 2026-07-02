#!/usr/bin/perl
# tidy-check.pl - changed-code-only perltidy gate (review D2).
#
# The existing tree keeps its hand-formatting; this checks only the lines a
# change TOUCHED against the .perltidyrc canonical form, so new and edited code
# is tidy without a whole-tree reformat.
#
#   perl tools/tidy-check.pl                 # files changed since the last tag
#   perl tools/tidy-check.pl --base REF      # ...since REF
#   perl tools/tidy-check.pl FILE...         # check whole files (all lines)
#
# Because .perltidyrc freezes newlines (-fnl), perltidy output has the same line
# count as its input, so an untidy line is found by a direct line-by-line
# compare. Exits non-zero if a touched line is not in tidy form. Skips cleanly
# when perltidy or git is unavailable.
use strict;
use warnings;
use Cwd            qw(abs_path);
use File::Basename qw(dirname);

my $root    = dirname( dirname( abs_path($0) ) );
my $rc_file = "$root/.perltidyrc";

my ( $base, @files );
while (@ARGV) {
    my $a = shift @ARGV;
    if ( $a eq '--base' ) { $base = shift @ARGV }
    else                  { push @files, $a }
}

exit_skip('perltidy not installed') if system('perltidy -v >/dev/null 2>&1') != 0;

# A production Perl file we gate (mirrors the compile/perlcritic sweep set).
sub is_prod {
    my ($f) = @_;
    return 0 unless $f =~ /\.p[lm]$/;
    return 0 if $f =~ m{^t/};
    return 1 if $f =~ m{^(?:[^/]+\.pl|tools/[^/]+\.pl|plugins/[^/]+\.pl|lib/Lazysite/.+\.pm)$}x;
    return 0;
}

my %touched;    # file => { line => 1 } of changed lines; empty hash = whole file
if (@files) {
    $touched{$_} = {} for grep { is_prod($_) } @files;    # whole-file check
}
else {
    unless ( -d "$root/.git" ) { exit_skip('not a git checkout; pass files explicitly') }
    $base ||= `git -C \Q$root\E describe --tags --abbrev=0 2>/dev/null`;
    chomp $base;
    exit_skip('no base ref (no tags); pass --base') unless length $base;

    my @changed = `git -C \Q$root\E diff --name-only \Q$base\E -- 2>/dev/null`;
    chomp @changed;
    for my $f ( grep { is_prod($_) } @changed ) {
        next unless -f "$root/$f";
        $touched{$f} = added_lines( $root, $base, $f );
    }
}

exit_ok('no changed production files to check') unless %touched;

my $fail = 0;
for my $f ( sort keys %touched ) {
    my $path   = -f $f ? $f : "$root/$f";
    my @orig   = read_lines($path) or next;
    my $tidied = `perltidy -pro=\Q$rc_file\E -st \Q$path\E 2>/dev/null`;
    my @tidy   = split /^/m, $tidied;
    if ( @tidy != @orig ) {
        # -fnl should keep the count; if not, fall back to reporting the file.
        print "TIDY: $f - perltidy changed the line count (review manually)\n";
        $fail = 1;
        next;
    }
    my $lines = $touched{$f};
    my $whole = !%{$lines};
    my @bad;
    for my $i ( 0 .. $#orig ) {
        next unless $orig[$i] ne $tidy[$i];
        my $ln = $i + 1;
        push @bad, $ln if $whole || $lines->{$ln};
    }
    if (@bad) {
        $fail = 1;
        my $shown = join( ', ', @bad[ 0 .. ( @bad > 12 ? 11 : $#bad ) ] );
        $shown .= ', …' if @bad > 12;
        print "TIDY: $f - " . scalar(@bad) . " touched line(s) not tidy: $shown\n";
    }
}

if ($fail) {
    print "\nRun: perltidy -b <file>  (or fix the flagged lines) to match .perltidyrc.\n";
    exit 1;
}
print "tidy-check: all touched production lines are tidy\n";
exit 0;

sub read_lines {
    my ($p) = @_;
    open my $fh, '<', $p or return ();
    my @l = <$fh>;
    close $fh;
    return @l;
}

# Line numbers ADDED/changed in $f in the working tree vs $base (new-file side).
sub added_lines {
    my ( $r, $b, $f ) = @_;
    my %add;
    my @hunks = `git -C \Q$r\E diff --unified=0 \Q$b\E -- \Q$f\E 2>/dev/null`;
    for my $h (@hunks) {
        next unless $h =~ /^\@\@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? \@\@/;
        my ( $start, $len ) = ( $1, defined $2 ? $2 : 1 );
        $add{$_} = 1 for $start .. ( $start + $len - 1 );
    }
    return \%add;
}

sub exit_skip { print "tidy-check: SKIP - $_[0]\n"; exit 0 }
sub exit_ok   { print "tidy-check: $_[0]\n";        exit 0 }
