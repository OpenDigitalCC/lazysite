#!/usr/bin/perl
# SM895 G3: a gate FAILURE keeps its stage; the next run removes what the last
# one left. --keep-stage means "even on success".
#
# SM328 removed the stage however the run ended, because four failed cuts in a
# day exhausted a tmpfs. SM560 made the abort sentence true about that. And
# then the first 0.14.3 cut ran the instrumented suite for two hours, the
# report step printed nothing, and the database it had failed to report on was
# deleted with the clone - so the second attempt was launched blind and failed
# the same way. A gate failure is exactly when somebody wants the stage.
#
# The reconciliation with SM328 is not "keep everything": it is that a run
# tidies its predecessors at START, when it knows which of them are dead, so
# at most one failed stage exists at a time and a live one is never touched.
#
# The three functions are lifted from release.sh and driven in a scratch
# STAGE_BASE, as t/tools/61 drives the abort sentence.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd);

my $root    = repo_root();
my $release = "$root/tools/release.sh";
plan skip_all => 'release.sh missing' unless -f $release;

my $src = do { open my $fh, '<', $release or die $!; local $/; <$fh> };

my ($cleanup) = $src =~ /^(cleanup_stage\(\) \{\n.*?\n\})\n/ms;
my ($report)  = $src =~ /^(stage_disposition\(\) \{\n.*?\n\})\n/ms;
my ($prune)   = $src =~ /^(prune_dead_stages\(\) \{\n.*?\n\})\n/ms;
ok( defined $cleanup, 'release.sh defines cleanup_stage()' );
ok( defined $report,  'release.sh defines stage_disposition()' );
ok( defined $prune,   'release.sh defines prune_dead_stages()' )
    or BAIL_OUT('nothing to drive');
like( $src, qr/^trap 'cleanup_stage \$\?' EXIT$/m,
    'the trap hands cleanup_stage the exit status - that is what it decides on' );

sub _write { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh }

# Run a script that ends with `exit $rc`, with the lifted functions in place.
sub run_end {
    my ( $rc, $keep ) = @_;
    my $d     = tempdir( CLEANUP => 1 );
    my $stage = "$d/lazysite-release-$$";
    mkdir $stage or die $!;
    _write( "$d/run.sh", <<"RUN" );
STAGE="$stage"
KEEP_STAGE=$keep
$cleanup
$report
trap 'cleanup_stage \$?' EXIT
[ "$rc" -eq 0 ] || stage_disposition
exit $rc
RUN
    my $out = run_cmd( 'bash', "$d/run.sh" );
    return ( $out, $stage );
}

subtest 'an abort KEEPS the stage, and says so' => sub {
    my ( $out, $stage ) = run_end( 1, 0 );
    ok( -d $stage, 'the stage is still there after a failed run' )
        or diag( 'This is the 0.14.3 case: two hours of measurement removed '
            . "at the moment it was needed.\n$out" );
    like( $out, qr/^release\.sh: staging dir retained: \Q$stage\E$/m,
        'and the abort line names it as retained' );
    like( $out, qr/next run/, 'and says when it goes' );
};

subtest 'success REMOVES the stage (SM328 still holds where it applies)' => sub {
    my ( $out, $stage ) = run_end( 0, 0 );
    ok( !-d $stage, 'the stage is gone after a successful run' ) or diag($out);
};

subtest '--keep-stage keeps a successful stage too' => sub {
    my ( $out, $stage ) = run_end( 0, 1 );
    ok( -d $stage, 'kept on success when asked' ) or diag($out);
};

subtest 'the next run removes dead stages and leaves live ones alone' => sub {
    my $base = tempdir( CLEANUP => 1 );

    # A dead pid: a child that has already been reaped.
    my $dead = fork();
    die "fork: $!" unless defined $dead;
    exit 0 if !$dead;
    waitpid $dead, 0;

    # A live pid: a child that is still sleeping.
    my $live = fork();
    die "fork: $!" unless defined $live;
    if ( !$live ) { sleep 1 for 1 .. 30; exit 0 }

    mkdir "$base/lazysite-release-$dead" or die $!;
    mkdir "$base/lazysite-release-$live" or die $!;
    mkdir "$base/lazysite-release-$$"    or die $!;    # this run's own
    mkdir "$base/unrelated"              or die $!;
    mkdir "$base/lazysite-release-notes" or die $!;    # matches the glob, is not a PID
    _write( "$base/lazysite-release-$dead-coverage-suite.txt", "the evidence\n" );

    _write( "$base/run.sh", <<"RUN" );
STAGE_BASE="$base"
$prune
prune_dead_stages
RUN
    # $$ inside run.sh is bash's own pid, so this run's directory is named by
    # a pid that is ALIVE (the test's), which is the same property.
    my $out = run_cmd( 'bash', "$base/run.sh" );
    kill 'TERM', $live;
    waitpid $live, 0;

    ok( !-d "$base/lazysite-release-$dead", 'the dead run\'s stage is removed' ) or diag($out);
    like( $out, qr/removing the stage a previous run left behind: \Q$base\E\/lazysite-release-$dead/,
        'and the removal is announced, naming it' );
    ok( -d "$base/lazysite-release-$live", 'a stage whose process is alive is left alone' )
        or diag("A concurrent cut's clone must never be pulled out from under it.\n$out");
    like( $out, qr/belongs to a live process/, 'and says why it was left' );
    ok( -d "$base/lazysite-release-$$", 'this run\'s own stage is left alone' );
    ok( -d "$base/unrelated", 'a directory that is not a stage is not touched' );
    ok( -d "$base/lazysite-release-notes",
        'a stage-shaped name that is not a PID is not touched - "not alive" is not the same as "dead"' )
        or diag( 'kill -0 on a non-number fails exactly as it does on a dead pid, '
            . 'so without the numeric guard anything matching the glob is removed.' );
    ok( -f "$base/lazysite-release-$dead-coverage-suite.txt",
        'the logs kept BESIDE a stage survive its removal - they are the evidence' );
};

done_testing();
