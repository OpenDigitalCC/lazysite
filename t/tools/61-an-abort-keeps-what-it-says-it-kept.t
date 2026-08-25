#!/usr/bin/perl
# SM560: an abort keeps what it says it kept.
#
# Thirteen abort paths in release.sh printed "staging dir retained: PATH" and
# the SM328 EXIT trap removed the directory on the way out unless --keep-stage
# was given. The engineer's first diagnostic step - look inside the path they
# were just told about - was a dead end every time.
#
# SM328's trap is the older lesson (retained clones exhausted a tmpfs) and it
# stays. What changes is the sentence: it must be TRUE. This lifts the helper
# and the trap from release.sh, aborts with and without --keep-stage, and
# asserts exactly one thing each time - the printed path exists, or the line
# says it was removed and how to keep it next time.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root    = repo_root();
my $release = "$root/tools/release.sh";
plan skip_all => 'release.sh missing' unless -f $release;

my $src = do { open my $fh, '<', $release or die $!; local $/; <$fh> };

# --- the shape: one helper, every abort path calls it ---------------------
my ($helper) = $src =~ /^(stage_disposition\(\) \{\n.*?\n\})\n/ms;
ok( defined $helper, 'release.sh defines stage_disposition()' )
    or BAIL_OUT('no helper to lift - the eleven literals are still inline');

my ($trap) = $src =~ /^(cleanup_stage\(\) \{[^\n]*\})\n/m;
ok( defined $trap, 'and the SM328 cleanup trap is still there' );

my @calls = $src =~ /^\s+stage_disposition$/mg;
cmp_ok( scalar @calls, '>=', 11, 'every abort path reports through the helper' )
    or diag( scalar(@calls) . ' calls found; the review counted eleven abort echoes plus two prose promises' );

my @bare = $src =~ /^(\s+echo "release\.sh: staging dir retained: \$STAGE" >&2)$/mg;
is( scalar @bare, 1,
    'the "retained" sentence is printed in exactly one place - inside the helper, '
        . 'where it is conditional on --keep-stage' )
    or diag("bare literals outside the helper: @bare");

# --- the behaviour: the sentence is true, both ways ----------------------
sub abort_with {
    my ($keep) = @_;
    my $d      = tempdir( 'lazysite-abort-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    my $stage  = "$d/lazysite-release-$$";
    mkdir $stage or die $!;
    open my $r, '>', "$d/run.sh" or die $!;
    print {$r} <<"RUN";
STAGE="$stage"
KEEP_STAGE=$keep
$trap
trap cleanup_stage EXIT
$helper
stage_disposition
exit 1
RUN
    close $r;
    my $out = qx(bash "$d/run.sh" 2>&1);
    my ($line) = $out =~ /^(release\.sh: staging dir [^\n]*)$/m;
    return ( $line // '', $stage );
}

for my $keep ( 0, 1 ) {
    my ( $line, $stage ) = abort_with($keep);
    my $label = $keep ? 'with --keep-stage' : 'without --keep-stage';
    ok( length $line, "$label: the abort says what became of the stage" )
        or next;
    my ($printed) = $line =~ /: (\S+)$/;
    ok( ( -d $printed ) || $line =~ /removed \(re-run with --keep-stage/,
        "$label: the printed path exists, or the line says it was removed and "
            . 'how to keep it' )
        or diag( "line: $line\nexists: " . ( -d $printed ? 'yes' : 'no' ) );
    if ($keep) {
        like( $line, qr/retained/, "$label: a kept stage is reported as retained" );
        ok( -d $stage, "$label: and it really is there" );
    }
    else {
        like( $line, qr/removed/, "$label: a removed stage is reported as removed" );
        ok( !-d $stage, "$label: and it really is gone (SM328 still holds)" );
    }
}

# --- the prose agrees ------------------------------------------------------
unlike( $src, qr/^# On abort: the staging dir is retained and its path printed/m,
    'the header no longer promises retention the trap does not deliver' );

done_testing();
