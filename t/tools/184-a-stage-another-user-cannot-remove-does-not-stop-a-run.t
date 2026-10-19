#!/usr/bin/perl
# SM1187: a failed stage another user cannot remove stopped the next run.
#
# 0.15.10 cut, 2026-10-19: the developer agent's gate (unix user claude) failed on
# the bench and kept its stage, as SM895 G3 says it should. The release manager
# then ran the gate as their own user and it stopped in 0 s:
#   rm: cannot remove '/var/tmp/lazysite-stage/lazysite-release-237354/docs/...':
#   Permission denied
# prune_dead_stages ran `rm -rf` under `set -e`, and every file in the stage was
# owned by claude, 0664/0775. The class: any leftover the current user cannot
# clear. A run clears the stages it can, NAMES the ones it cannot (owner, age, the
# command to remove it) as a warning, and carries on; its own stage has a
# directory of its own (the pid is in the name), so the leftover is no obstacle.
# A stage root the user cannot write at all gets a per-user root
# (tools/stage-default.sh), not a refusal.
#
# We cannot use another real user, so "cannot remove" is a directory in the
# stage whose own mode is 0555 (entries in it cannot be unlinked by its owner).
# The functions are lifted from release.sh and driven under `set -e`, as the real
# script runs.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd);

plan skip_all => 'running as root: nothing is unremovable' if $> == 0;

my $root    = repo_root();
my $release = "$root/tools/release.sh";
my $src     = do { open my $fh, '<', $release or die $!; local $/; <$fh> };

my ($cleanup) = $src =~ /^(cleanup_stage\(\) \{\n.*?\n\})\n/ms;
my ($report)  = $src =~ /^(stage_disposition\(\) \{\n.*?\n\})\n/ms;
my ($prune)   = $src =~ /^(prune_dead_stages\(\) \{\n.*?\n\})\n/ms;
ok( defined $prune && defined $report && defined $cleanup, 'release.sh defines the three stage functions' )
    or BAIL_OUT('nothing to drive');

sub _write { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh }

# A pid that is dead: a child already reaped.
sub dead_pid {
    my $p = fork();
    die "fork: $!" unless defined $p;
    exit 0 if !$p;
    waitpid $p, 0;
    return $p;
}

# A stage with a file under a directory this user cannot write into.
sub locked_stage {
    my ($path) = @_;
    mkdir $path or die $!;
    mkdir "$path/docs" or die $!;
    _write( "$path/docs/SM789-a-kept-file.md", "kept\n" );
    chmod 0555, "$path/docs" or die $!;
}

sub unlock { my ($p) = @_; chmod 0755, "$p/docs" if -d "$p/docs" }

my $user = getpwuid($>);

subtest 'a leftover this user cannot remove is named, not fatal' => sub {
    my $base = tempdir( CLEANUP => 1 );
    my $dead = dead_pid();
    my $old  = "$base/lazysite-release-$dead";
    locked_stage($old);
    utime( time - 3 * 86400, time - 3 * 86400, $old );
    my $mine = dead_pid();    # a second dead stage that CAN be cleared
    mkdir "$base/lazysite-release-$mine" or die $!;
    _write( "$base/run.sh", <<"RUN" );
set -e
STAGE_BASE="$base"
$prune
prune_dead_stages
echo REACHED-AFTER-PRUNE
RUN
    my $out = run_cmd( 'bash', "$base/run.sh" );
    like( $out, qr/REACHED-AFTER-PRUNE/, 'the run goes on past the stage it cannot clear' )
        or diag($out);
    ok( -d $old, 'the stage it could not clear is not half-removed' );
    like( $out, qr/could not remove the stage .*\Q$old\E/, 'the warning names it' );
    like( $out, qr/owned by \Q$user\E/,                    'and who owns it' );
    like( $out, qr/\b3 days? old\b/,                       'and how old it is' );
    like( $out, qr/rm -rf \Q$old\E/,                       'and the command to remove it' );
    ok( !-d "$base/lazysite-release-$mine", 'a leftover it can clear is still cleared' );
    unlock($old);
};

subtest 'the failed run keeps its own stage and says who can remove it' => sub {
    my $base  = tempdir( CLEANUP => 1 );
    my $stage = "$base/lazysite-release-$$";
    mkdir $stage or die $!;
    _write( "$base/run.sh", <<"RUN" );
STAGE="$stage"
KEEP_STAGE=0
$cleanup
$report
trap 'cleanup_stage \$?' EXIT
stage_disposition
exit 1
RUN
    my $out = run_cmd( 'bash', "$base/run.sh" );
    ok( -d $stage, 'the failed stage is kept' );
    like( $out, qr/retained: \Q$stage\E/, 'and named' );
    like( $out, qr/\Q$user\E (?:\(.*?\) )?(?:or root )?can remove/i, 'with who can remove it' )
        or diag($out);
    like( $out, qr/rm -rf \Q$stage\E/, 'and the command' );
};

subtest 'the run\'s own stale stage from an earlier run is removed' => sub {
    my $base = tempdir( CLEANUP => 1 );
    my $dead = dead_pid();
    mkdir "$base/lazysite-release-$dead" or die $!;
    _write( "$base/lazysite-release-$dead/file", "x\n" );
    _write( "$base/run.sh", <<"RUN" );
set -e
STAGE_BASE="$base"
$prune
prune_dead_stages
RUN
    my $out = run_cmd( 'bash', "$base/run.sh" );
    ok( !-d "$base/lazysite-release-$dead", 'removed' ) or diag($out);
    unlike( $out, qr/could not remove/, 'with no warning' );
};

subtest 'a stage root this user cannot write gets a per-user root' => sub {
    my $tmp  = tempdir( CLEANUP => 1 );
    my $base = "$tmp/lazysite-stage";
    mkdir $base or die $!;
    chmod 0555, $base or die $!;
    local $ENV{LAZYSITE_STAGE_DEFAULT} = $base;
    delete $ENV{LAZYSITE_STAGE_DIR};
    my $out = run_cmd( 'bash', "$root/tools/stage-default.sh" );
    chmod 0755, $base;
    like( $out, qr{^\Q$base\E-\Q$user\E$}m, 'the default is the per-user root' ) or diag($out);
    ok( -d "$base-$user", 'and it is made' );
    ok( -w "$base-$user", 'and the user can write it' );
    like( $out, qr/not writable/, 'with a line saying why' );
};

subtest 'an explicit stage dir this user cannot write is refused with the way out' => sub {
    my $tmp = tempdir( CLEANUP => 1 );
    mkdir "$tmp/ro" or die $!;
    chmod 0555, "$tmp/ro" or die $!;
    my $out = run_cmd( 'bash', $release, 'gate', '9.9.9', '--stage-dir', "$tmp/ro" );
    chmod 0755, "$tmp/ro";
    like( $out, qr/stage dir \Q$tmp\E\/ro is not writable by \Q$user\E; not releasing/, 'named and refused' )
        or diag($out);
    like( $out, qr/--stage-dir DIR/, 'with the way out' );
};

done_testing();
