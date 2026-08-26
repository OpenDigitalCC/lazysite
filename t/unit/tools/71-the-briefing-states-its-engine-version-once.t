#!/usr/bin/perl
# SM620: the generated briefing names the engine version ONCE for a reader.
#
# It named it twelve times. Every release must re-import the file - the header
# records the version and t/lint/89 requires it to match the build - so a cut
# rewrote twelve lines with the SOURCES BYTE-IDENTICAL, and two of those lines
# were wrong rather than merely repetitive:
#
#   *Version-independent - a field scar. It held before engine 0.11.0 and
#    holds after it, on any site you connect to.*
#
# A sentence whose entire claim is that the version does not matter, anchored to
# whichever version was last cut. On 0.11.5 it told the reader a version-
# independent scar held before 0.11.5 - true, uninformative, and quietly
# narrower than the author meant. It names no version now, because that is what
# version-independent means.
#
# The operator settled the same shape in FEATURES.md (SM609): keep ONE reference
# to the version the file relates to. Here that is the machine header, which
# t/lint/89 reads, plus one prose stamp where a reader meets it before acting on
# anything. The provenance section points at that stamp instead of carrying a
# second copy.
#
# THE ASSERTIONS RUN THE GENERATOR AT TWO VERSIONS and diff the output, rather
# than counting occurrences in the checked-in file. What matters is not how many
# times a number appears today - it is how much a VERSION BUMP rewrites, which
# is the cost this exists to remove, and the only way to see it is to bump.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use FindBin;

my $root = "$FindBin::Bin/../../..";
my $tool = "$root/tools/import-field-practice.pl";
my $out  = "$root/starter/docs/ai-briefing-practice.md";
plan skip_all => "no $tool" unless -f $tool;
plan skip_all => "no $out"  unless -f $out;

# The generator writes in place, so preserve and restore. A test that left the
# repo's briefing stamped 9.9.9 would fail the next release rather than this one.
my $dir  = tempdir( CLEANUP => 1 );
my $save = "$dir/original";
copy( $out, $save ) or die "preserve: $!";

sub regen {
    my ($v) = @_;
    my $rc = system( $^X, $tool, '--engine-version', $v );
    die "generator failed for $v\n" if $rc != 0;
    open my $fh, '<', $out or die $!;
    local $/;
    return <$fh>;
}

my ( $a, $b );
my $ok = eval { $a = regen('1.2.3'); $b = regen('9.8.7'); 1 };
copy( $save, $out )                            or die "restore: $!";
ok( $ok, 'the generator ran at two versions' ) or do { done_testing(); exit };

# --- 1. a version bump rewrites three lines, not twelve ---------------------
my @al = split /\n/, $a;
my @bl = split /\n/, $b;
is( scalar @al, scalar @bl, 'the two renderings have the same shape' );

my @differ = grep { ( $al[$_] // '' ) ne ( $bl[$_] // '' ) } 0 .. $#al;
cmp_ok( scalar @differ, '<=', 3,
    'a version bump changes at most three lines: the header stamp, the body '
        . 'hash it implies, and one prose stamp' )
    or diag( join "\n", map { "  - $al[$_]\n  + $bl[$_]" } @differ );

# Name them, so a future change that swaps WHICH three lines move is visible
# rather than merely staying under the count.
my $moved = join "\n", map { $al[$_] } @differ;
like( $moved, qr/engine-version:/,      'the machine header is one of them' );
like( $moved, qr/body-sha256:/,         'the body hash is another' );
like( $moved, qr/generated for engine/, 'and the single prose stamp' );

# --- 2. no NOTE carries a version ------------------------------------------
# The specific defect. A version-dated note may say "check which engine"; it may
# not name one, because the answer is at the top and this copy is not it.
for my $pair ( [ '1.2.3', $a ], [ '9.8.7', $b ] ) {
    my ( $v, $doc ) = @$pair;
    my @noted = grep { /^\*Version-(?:dated|independent)/ && /\d+\.\d+\.\d+/ }
        split /\n/, $doc;
    is_deeply( \@noted, [],
        "at $v, no version-dated or version-independent note names a version" )
        or diag( join "\n", @noted );
}

# --- 3. the version-independent note does not mention a version at all ------
# Stronger than "not THIS version": the claim is that no version applies.
{
    my ($scar) = $a =~ /^(\*Version-independent[^\n]*)/m;
    ok( $scar, 'the field-scar note is present' );
    unlike( $scar, qr/\d+\.\d+\.\d+/,
        'and names no version - which is what version-independent means' );
    like( $scar, qr/whatever engine|any site/,
        'saying instead that it holds regardless' );
}

# --- 4. the file was restored -----------------------------------------------
# The generator writes in place; leaving 9.8.7 behind would break the next cut.
{
    open my $fh, '<', $out or die $!;
    local $/;
    my $now = <$fh>;
    open my $sfh, '<', $save or die $!;
    my $orig = <$sfh>;
    is( $now, $orig, 'the checked-in briefing is byte-identical after the test' );
}

done_testing();
