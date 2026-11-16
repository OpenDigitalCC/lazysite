#!/usr/bin/perl
# SM1454 (R3): tools/suite-lab.sh runs the suite on an HPS lab VM or, when the lab
# is not available, locally - and it never turns a failed run into a pass.
#
# NOTHING HERE REACHES THE LAB. lab-op, hps-flavour and ssh are stand-ins on
# LAZYSITE_LAB_OP / _FLAVOUR / _SSH that log their arguments and answer from the
# environment; the local runner is the real tools/suite-local.sh over a staged
# tree of two tiny tests, or a marker stand-in where the point is that it is NOT
# run.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $root  = repo_root();
my $lab   = "$root/tools/suite-lab.sh";
my $local = "$root/tools/suite-local.sh";
plan skip_all => "no $lab" unless -f $lab && -f $local;

sub spit {
    my ( $p, $t, $mode ) = @_;
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    chmod $mode, $p if $mode;
    return;
}

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or return '';
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t;
}

my $work = site_tempdir() . '/..';
make_path("$work/bin");
my $log = "$work/stub.log";

# lab-op: answers per verb; STUB_* in the environment steer it.
spit( "$work/bin/lab-op", <<'SH', 0755 );
#!/bin/sh
echo "lab-op $*" >> "$STUB_LOG"
case "$1" in
  hps-issues) [ "${STUB_ISSUES_RC:-0}" = 0 ] || exit 1; echo "${STUB_ISSUES:-no issues}" ;;
  hps-node) echo "COMMITTED vcpus=1 free_mem_mib=${STUB_FREE:-44171}"; exit 141 ;;
  --input) cat > /dev/null; exit "${STUB_DEFINE_RC:-0}" ;;
  hps-workload)
    case "$2" in
      create) exit "${STUB_CREATE_RC:-0}" ;;
      console) echo "HPS-READY name=$3 addr=enp1s0=10.100.1.150/24"; echo "HPS-CLOUD-INIT done after 9 s" ;;
      destroy) exit "${STUB_DESTROY_RC:-0}" ;;
    esac ;;
esac
exit 0
SH

spit( "$work/bin/hps-flavour", <<'SH', 0755 );
#!/bin/sh
echo "hps-flavour $*" >> "$STUB_LOG"
name=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in --name) name=$2 ;; --out) out=$2 ;; esac
  shift
done
printf '{"name":"%s","vms":[{"name":"%s","memory_mib":16384,"vcpus":8}]}\n' "$name" "$name" > "$out/$name.json"
SH

# ssh: the last argument is the remote command.
spit( "$work/bin/ssh", <<'SH', 0755 );
#!/bin/sh
for last; do :; done
echo "ssh $last" >> "$STUB_LOG"
case "$last" in
  true) exit 0 ;;
  "sudo bash -s"|*"tar -C suite"*) cat > /dev/null; exit 0 ;;
  *prove*) echo "${STUB_PROVE_OUT:-All tests successful.
Result: PASS}"; exit "${STUB_PROVE_RC:-0}" ;;
esac
exit 0
SH

spit( "$work/bin/local-marker", "#!/bin/sh\necho local-ran >> \"\$STUB_LOG\"\nexit 99\n", 0755 );
spit( "$work/key",     "not a key\n" );
spit( "$work/key.pub", "not a key\n" );

# A staged tree: one passing test.
sub stage {
    my ( $name, $body ) = @_;
    my $d = "$work/stage-$name";
    make_path("$d/t");
    spit( "$d/t/a.t", $body );
    return $d;
}

# Run suite-lab.sh; returns (exit status, stdout+stderr, outfile text).
my $n = 0;

sub run_lab {
    my ( $stage, $env ) = @_;
    $n++;
    my $out = "$work/out-$n.txt";
    unlink $log;
    local %ENV = (
        %ENV,
        STUB_LOG              => $log,
        LAZYSITE_LAB_OP       => "$work/bin/lab-op",
        LAZYSITE_LAB_FLAVOUR  => "$work/bin/hps-flavour",
        LAZYSITE_LAB_SSH      => "$work/bin/ssh",
        LAZYSITE_LAB_KEY      => "$work/key",
        LAZYSITE_LAB_HOUR     => 10,
        LAZYSITE_LAB_POLL     => 0,
        LAZYSITE_LAB_WAIT     => 3,
        %{ $env || {} },
    );
    delete $ENV{LAZYSITE_SUITE_LAB} unless exists $env->{LAZYSITE_SUITE_LAB};
    my $txt = qx(bash \Q$lab\E \Q$stage\E 2 \Q$out\E 2>&1 </dev/null);
    return ( $? >> 8, $txt, slurp($out), slurp($log) );
}

my $pass = stage( 'pass', "use Test::More tests => 1; ok(1, 'fine');\n" );
my $fail = stage( 'fail', "use Test::More tests => 1; ok(0, 'broken');\n" );

# 1. Not enabled: the one-line reason, the local run, the lab never touched.
{
    my ( $rc, $txt, $out, $calls ) = run_lab( $pass, {} );
    is( $rc, 0, 'lab path off: the local suite passes, exit 0' );
    like( $txt, qr/^suite-lab: lab not available \(LAZYSITE_SUITE_LAB is not 1\) - running locally$/m, 'says why, in one line' );
    like( $out, qr/^Result: PASS/m, 'OUTFILE holds prove output' );
    is( $calls, '', 'no lab-op, hps-flavour or ssh call was made' );
}

# 2. The local run's status is prove's: a failing test fails the runner.
{
    my ( $rc, $txt, $out ) = run_lab( $fail, {} );
    isnt( $rc, 0, 'a failing local suite exits non-zero' );
    like( $out, qr/^Result: FAIL/m, 'OUTFILE says FAIL' );
}

# 3. The check says unavailable: each reason falls back and starts no VM.
for my $case (
    [ 'quiet hours', { LAZYSITE_SUITE_LAB => 1, LAZYSITE_LAB_HOUR => 22 }, qr/\(HPS quiet hours/, 0 ],
    [ 'IPS silent',  { LAZYSITE_SUITE_LAB => 1, STUB_ISSUES_RC => 1 }, qr/\(the lab IPS does not answer\)/, 1 ],
    [ 'open issue', { LAZYSITE_SUITE_LAB => 1, STUB_ISSUES => 'needs-human sch-001 pool lab' }, qr/\(an open issue names sch-001/, 1 ],
    [ 'no memory',   { LAZYSITE_SUITE_LAB => 1, STUB_FREE => 1000 }, qr/\(free guest memory 1000 MiB/, 1 ],
    [ 'no key', { LAZYSITE_SUITE_LAB => 1, LAZYSITE_LAB_KEY => "$work/absent" }, qr/\(no ssh key /, 0 ],
  )
{
    my ( $name, $env, $re, $asks ) = @$case;
    my ( $rc, $txt, $out, $calls ) = run_lab( $pass, $env );
    like( $txt, $re, "$name: reason named" );
    is( $rc, 0, "$name: runs locally and passes" );
    like( $out, qr/^Result: PASS/m, "$name: OUTFILE is the local run's" );
    unlike( $calls, qr/hps-workload (create|start)/, "$name: no VM was created" );
}

# 4. A lab failure before the tests start falls back, and destroys what it made.
{
    my ( $rc, $txt, $out, $calls ) = run_lab( $pass, { LAZYSITE_SUITE_LAB => 1, STUB_CREATE_RC => 1 } );
    like( $txt, qr/lab not available \(create lazysite-suite-\d+ failed/, 'create failure: named, falls back' );
    is( $rc, 0, 'create failure: the local suite ran and passed' );
    like( $calls, qr/hps-workload destroy lazysite-suite-\d+ --forget/, 'create failure: the VM is destroyed' );
    unlike( $calls, qr/prove/, 'create failure: nothing ran on the VM' );
}

# 5. The lab path, end to end: the VM runs the suite, OUTFILE and status come
#    from it, the local runner is not run, and the VM is destroyed.
{
    my ( $rc, $txt, $out, $calls ) = run_lab( $pass, { LAZYSITE_SUITE_LAB => 1, LAZYSITE_SUITE_LOCAL => "$work/bin/local-marker" } );
    is( $rc, 0, 'lab run: exit 0' );
    like( $out, qr/^Result: PASS/m, 'lab run: OUTFILE is the VM\'s prove output' );
    like( $calls, qr/prove -lr -j8 t\//, 'lab run: prove ran on the VM at its 8 vCPUs' );
    unlike( $calls, qr/local-ran/, 'lab run: the local runner did not run' );
    like( $calls, qr/--memory 16384 --vcpus 8/, 'lab run: sized 8 vCPU / 16 GiB' );
    like( $calls, qr/hps-workload start .*\n(?:.*\n)*.*hps-workload destroy lazysite-suite-\d+ --forget\n\z/, 'lab run: destroyed after the run' );
    like( $txt, qr/destroyed VM lazysite-suite-\d+/, 'lab run: says it destroyed the VM' );
}

# 6. A failure after the tests started is a failure, never a fallback.
{
    my ( $rc, $txt, $out, $calls ) = run_lab(
        $pass,
        {
            LAZYSITE_SUITE_LAB   => 1,
            LAZYSITE_SUITE_LOCAL => "$work/bin/local-marker",
            STUB_PROVE_RC        => 1,
            STUB_PROVE_OUT       => "Test Summary Report\nResult: FAIL",
        }
    );
    is( $rc, 1, 'lab failure after start: exit 1 (prove\'s status)' );
    like( $out, qr/^Result: FAIL/m, 'lab failure after start: OUTFILE carries the failure' );
    unlike( $calls, qr/local-ran/, 'lab failure after start: no local fallback' );
    like( $calls, qr/hps-workload destroy/, 'lab failure after start: the VM is still destroyed' );
}

# 7. Exit 0 with no "Result: PASS" is not a pass.
{
    my ( $rc, $txt ) = run_lab(
        $pass,
        { LAZYSITE_SUITE_LAB => 1, LAZYSITE_SUITE_LOCAL => "$work/bin/local-marker", STUB_PROVE_OUT => 'lost the summary' }
    );
    is( $rc, 1, 'a clean exit without a PASS line is a failure' );
    like( $txt, qr/without a 'Result: PASS' line/, '... and says so' );
}

# 8. A VM that cannot be destroyed is shouted about, and the verdict stands.
{
    my ( $rc, $txt ) = run_lab( $pass, { LAZYSITE_SUITE_LAB => 1, STUB_DESTROY_RC => 1 } );
    like( $txt, qr/\*\*\* VM lazysite-suite-\d+ WAS NOT DESTROYED/, 'a failed destroy is named' );
    is( $rc, 0, '... and does not change a real pass' );
}

# 9. The contract's argument check.
{
    my $txt = qx(bash \Q$lab\E 2>&1);
    is( $? >> 8, 2, 'no arguments: exit 2' );
    like( $txt, qr/usage: tools\/suite-lab\.sh STAGE_DIR JOBS OUTFILE/, 'usage names the contract' );
}

done_testing;
