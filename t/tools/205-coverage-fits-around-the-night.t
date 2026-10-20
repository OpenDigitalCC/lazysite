#!/usr/bin/env perl
# SM1230: COVERAGE FITS AROUND THE NIGHT'S OTHER WORK. The 01:30 cover-once of
# 2026-10-20 was refused by its preflight: "swap in use 2904 MB is over 1024 MB
# and MemAvailable 7075 MB is under 7168 MB". The host carries several GB of
# swap all day from other agents' work, so swap in use must not refuse; only a
# host that truly cannot hold one worker does. The run itself is gentle (nice
# 19, ionice idle, 2 jobs), one at a time, and a later run resumes the groups an
# earlier one did not finish (each group's pass is recorded as it ends).
#
# Nothing is instrumented: tools/coverage-parts.sh is driven with a stand-in
# for tools/coverage.sh (LAZYSITE_COVER_RUNNER) and stand-ins for nice/ionice.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Fcntl      qw(:flock);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd);

my $root = repo_root();
delete @ENV{ grep { /^LAZYSITE_(?:STAGE_|PF_|HEAVY_|COVER_|NIGHTLY_)/ } keys %ENV };
my $tmp = tempdir( CLEANUP => 1 );
my $pf  = "$root/tools/preflight.sh";

sub meminfo {
    my ( $avail, $swt, $swf ) = @_;
    our $n;
    $n++;
    open my $f, '>', "$tmp/meminfo$n" or die;
    print {$f} "MemAvailable: $avail kB\nSwapTotal: $swt kB\nSwapFree: $swf kB\n";
    close $f;
    return "$tmp/meminfo$n";
}
sub run_in {
    my ( $env, @cmd ) = @_;
    local @ENV{ keys %$env } = values %$env;
    my $o = run_cmd(@cmd);
    return ( $? >> 8, $o );
}
my %ok = ( LAZYSITE_PF_MIN_INODES => 1, LAZYSITE_PF_MIN_DISK_KB => 1, LAZYSITE_HEAVY_LOCK => "$tmp/heavy.lock" );

# 1. The preflight at the figures that refused the 2026-10-20 run.
my ( $rc, $o ) = run_in( { %ok, LAZYSITE_PF_MEMINFO => meminfo( 7075 * 1024, 4_000_000, 4_000_000 - 2904 * 1024 ) }, 'bash', $pf, 'HEAVY', $tmp );
is( $rc, 0, 'swap 2904 MB in use with 7075 MB available goes' ) or diag($o);
like( $o, qr/^preflight: note - swap in use 2904 MB/m, 'swap in use is a note' );
unlike( $o, qr/not now/, 'not a refusal' );

# 2. It refuses when one worker cannot fit, and names memory (not swap).
( $rc, $o ) = run_in( { %ok, LAZYSITE_PF_MEMINFO => meminfo( 4000 * 1024, 4_000_000, 4_000_000 - 2904 * 1024 ) }, 'bash', $pf, 'HEAVY', $tmp );
is( $rc, 3, 'MemAvailable 4000 MB is "not now"' );
like( $o, qr/^preflight: not now - MemAvailable 4000 MB is under 5120 MB$/m, 'naming memory and the floor' );

# 3. The driver, with stand-ins.
my $bin = "$tmp/bin";
make_path($bin);
my $log = "$tmp/log";
sub put {
    my ( $path, $body ) = @_;
    open my $f, '>', $path or die "$path: $!";
    print {$f} $body;
    close $f;
    chmod 0755, $path;
}
put( "$bin/nice",   "#!/bin/sh\necho \"nice \$*\" >> $log\nshift 2\nexec \"\$@\"\n" );
put( "$bin/ionice", "#!/bin/sh\necho \"ionice \$*\" >> $log\nshift 1\nexec \"\$@\"\n" );
put( "$tmp/runner.sh", <<"RUNNER" );
#!/bin/sh
echo "run \$LAZYSITE_COVER_GROUP jobs=\${LAZYSITE_COVER_JOBS:-unset}" >> $log
[ "\$LAZYSITE_COVER_GROUP" = "\${STUB_FAIL_GROUP:-}" ] && exit 1
mkdir -p "\$(dirname "\$LAZYSITE_COVER_RECORD")"
echo '{ "result": "pass" }' > "\$LAZYSITE_COVER_RECORD"
RUNNER

my $store = "$tmp/store";
my @groups = map { ( split /\t/ )[0] } grep { /\tstale\t/ } split /\n/, run_cmd( 'perl', "$root/tools/coverage-groups.pl", '--state', $store );
cmp_ok( scalar(@groups), '>=', 2, 'the group map has at least two groups to resume across' );

my %run = (
    %ok,
    PATH                  => "$bin:$ENV{PATH}",
    LAZYSITE_PF_MEMINFO   => meminfo( 7075 * 1024, 4_000_000, 1_000_000 ),
    LAZYSITE_COVER_RUNNER => "$tmp/runner.sh",
    LAZYSITE_COVER_STORE  => $store,
    LAZYSITE_COVER_RECORD => "$tmp/combined.json",
    TMPDIR                => $tmp,
);
sub parts { my (@a) = @_; return run_in( {%run}, 'bash', "$root/tools/coverage-parts.sh", @a ) }
sub slurp { open my $f, '<', $_[0] or return ''; local $/; return <$f> }

# 4. The whole run is nice 19 + ionice idle, 2 jobs, despite 2904 MB of swap in use.
$run{LAZYSITE_PF_MEMINFO} = meminfo( 7075 * 1024, 4_000_000, 4_000_000 - 2904 * 1024 );
$run{STUB_FAIL_GROUP}     = $groups[1];
( $rc, $o ) = parts('--check');
my $l = slurp($log);
like( $l, qr/^nice -n 19 ionice -c3 bash /m, 'the run is started under nice 19 and ionice idle' );
like( $l, qr/^run \Q$groups[0]\E jobs=2$/m, 'a group runs with 2 jobs' );
unlike( $l, qr/jobs=(?:[013-9]|unset)/, 'and no group runs with any other count' );
isnt( $rc, 0, 'a failing group stops the run' );
like( $o, qr/group \Q$groups[1]\E: FAILED/, 'naming the group' );
unlike( $o, qr/not now/, 'swap did not refuse it' );

# 5. A later run resumes: the group that passed is reused, not run again.
unlink $log;
delete $run{STUB_FAIL_GROUP};
( $rc, $o ) = parts('--check');
$l = slurp($log);
is( $rc, 0, 'the resumed run finishes' ) or diag($o);
like( $o, qr/group \Q$groups[0]\E: REUSED/, 'the finished group is reused' );
unlike( $l, qr/^run \Q$groups[0]\E /m, 'and not run again' );
like( $l, qr/^run \Q$groups[1]\E /m, 'the unfinished group runs' );

# 6. A second start while one is running is refused, not queued.
open my $lk, '>>', "$store/.run.lock" or die;
flock( $lk, LOCK_EX | LOCK_NB ) or die 'cannot take the run lock';
unlink $log;
( $rc, $o ) = parts( '--check', '--all' );
is( $rc, 2, 'a second start while a run holds the run lock exits 2' );
like( $o, qr/another coverage run is in progress/, 'and says so' );
unlike( slurp($log), qr/^run /m, 'and ran no group' );
close $lk;

# 7. A host that cannot hold one worker skips (3), unchanged.
$run{LAZYSITE_PF_MEMINFO} = meminfo( 3000 * 1024, 4_000_000, 4_000_000 );
( $rc, $o ) = parts( '--check', '--all' );
is( $rc, 3, 'too little memory is "not now"' );
like( $o, qr/MemAvailable 3000 MB is under 5120 MB/, 'naming memory' );

done_testing;
