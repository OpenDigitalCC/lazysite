#!/usr/bin/perl
# SM950 (2): THE GATE RUNS ON MAIN AFTER A LANDING, ONCE PER COMMIT.
#
# A cut used to start with an hour-long gate, and any commit after a passing one
# restarted it: three gates for 0.15.2. tools/gate-main.sh gates main's tip for
# the next version after each landing, so a receipt is usually there when the
# cut is called. What it must get right, each asserted below against a stand-in
# release.sh in a scratch repository (the real gate is never run here):
#
#   - it runs `release.sh gate VERSION --commit SHA`, detached - its own
#     session, stdin from /dev/null, its lock not inherited - so nothing can
#     prompt (t/lint/208);
#   - a passed receipt for the same commit, version and channel is printed, and
#     nothing runs again;
#   - every commit is gated for real - the gate writes the release material
#     into its stage, so there is no pre-cut pass to wait for and no rehearsal
#     (SM971) - and a receipt from before that is not taken as "already gated";
#   - the version is NEXT_VERSION, and only when it is what release.sh would
#     propose; a burned version, a second concurrent run and a failed gate are
#     each refused or reported, never guessed past.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use Fcntl      qw(:flock);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd);

my $root = repo_root();
plan skip_all => 'setsid or flock missing' unless grep { -x "$_/setsid" } split /:/, $ENV{PATH};

sub spit {
    my ( $p, $t ) = @_;
    ( my $d = $p ) =~ s{/[^/]+$}{};
    make_path($d);
    open my $f, '>', $p or die "$p: $!";
    print {$f} $t;
    close $f;
}
sub slurp { open my $f, '<', $_[0] or return ''; local $/; my $t = <$f>; close $f; $t }

# The stand-in records how it was started, then behaves like a gate: a receipt
# for what it was asked, or a failure when STANDIN_FAIL is set.
my $STANDIN = <<'SH';
#!/bin/bash
ROOT=$(cd "$(dirname "$0")/.." && pwd)
{
    echo "ARGS $*"
    read -r _ _ _ _ _ sid _ < /proc/$$/stat
    [ "$sid" = "$$" ] && echo "SESSION-LEADER"
    [ "$(readlink /proc/$$/fd/0)" = /dev/null ] && echo "STDIN-NULL"
    [ -e /proc/$$/fd/9 ] && echo "FD9-INHERITED"
} >> "$ROOT/calls"
if [ -n "${STANDIN_FAIL:-}" ]; then echo "the suite failed here"; exit 1; fi
V=$2 SHA=$4 CH=edge
for a in "$@"; do
    case $a in --beta) CH=beta ;; --final) CH=stable ;; esac
done
mkdir -p "$ROOT/tmp/release-gate/$V"
printf 'sha=%s\nversion=%s\nchannel=%s\nresult=pass\ncoverage=reused\ncoverage_from=sha=abc\nmaterial_tool=abc\nfinished=now\n' \
    "$SHA" "$V" "$CH" > "$ROOT/tmp/release-gate/$V/receipt"
SH

sub git { my ( $d, @a ) = @_; my $o = run_cmd( 'git', '-C', $d, @a ); die "git @a: $o" if $?; chomp $o; $o }

sub repo {
    my (%o) = @_;
    my $d = tempdir( CLEANUP => 1 );
    git( $d, 'init',   '-q',         '-b', 'main' );
    git( $d, 'config', 'user.email', 't@example.invalid' );
    git( $d, 'config', 'user.name',  't' );
    spit( "$d/VERSION",      "0.1.0\n" );
    spit( "$d/NEXT_VERSION", ( $o{next} // '0.1.1' ) . "\n" );
    spit( "$d/starter/docs/ai-briefing-practice.md", "---\nprovenance:\n    engine-version: " . ( $o{stamp} // '0.1.1' ) . "\n---\n" );
    spit( "$d/.gitignore",       "tmp/\ncalls\n" );
    spit( "$d/tools/release.sh", $STANDIN );
    copy( "$root/tools/gate-main.sh", "$d/tools/gate-main.sh" ) or die $!;
    git( $d, 'add',    '-A' );
    git( $d, 'commit', '-q', '-m', 'one' );
    git( $d, 'tag',    'v0.1.0' );
    return $d;
}

# Started with stdin from a FILE, not /dev/null: the suite itself may run with
# stdin from /dev/null, and then a gate-main that forgot the redirect would
# still look detached.
sub gate_main {
    my ( $d, @args ) = @_;
    open my $save, '<&', \*STDIN      or die $!;
    open STDIN,    '<',  "$d/VERSION" or die $!;
    my $out = run_cmd( 'bash', "$d/tools/gate-main.sh", @args );
    my $rc  = $? >> 8;
    open STDIN, '<&', $save or die $!;
    return ( $rc, $out );
}
sub calls { my @c = grep { /^ARGS / } split /\n/, slurp("$_[0]/calls"); return scalar @c }
sub commit { my ($d) = @_; spit( "$d/f", rand() ); git( $d, 'add', 'f' ); git( $d, 'commit', '-q', '-m', 'more' ); git( $d, 'rev-parse', 'HEAD' ) }

subtest 'a cut-ready tip is gated for real, detached' => sub {
    my $d   = repo();
    my $sha = git( $d, 'rev-parse', 'HEAD' );
    my ( $rc, $out ) = gate_main($d);
    is( $rc, 0, 'exit 0' ) or diag($out);
    my $c = slurp("$d/calls");
    like( $c, qr/^ARGS gate 0\.1\.1 --commit $sha$/m, 'release.sh gate NEXT_VERSION --commit SHA, nothing else' );
    like( $c, qr/^SESSION-LEADER$/m, 'in a session of its own (setsid), so no terminal' );
    like( $c, qr/^STDIN-NULL$/m,     'with stdin from /dev/null' );
    unlike( $c, qr/FD9-INHERITED/, 'and without the lock, which a leftover process would hold for ever' );
    like( $out, qr/pass for \Q${\ substr( $sha, 0, 12 )}\E .*coverage reused/, 'it reports the result and the coverage' );
    ok( -f "$d/tmp/release-gate/0.1.1/gate-main.log", 'the output is kept beside the receipt' );
};

subtest 'a passed receipt for the same commit is printed, not re-run' => sub {
    my $d = repo();
    gate_main($d);
    my ( $rc, $out ) = gate_main($d);
    is( $rc, 0, 'exit 0' );
    like( $out, qr/already gated - not running it again/, 'says so' );
    like( $out, qr/^    result=pass$/m,                   'and prints the receipt' );
    is( calls($d), 1, 'release.sh ran once' );

    my $sha2 = commit($d);
    ( $rc, $out ) = gate_main($d);
    is( calls($d), 2, 'a new landing is gated again' );
    like( $out, qr/superseding the receipt/, 'naming the receipt it replaces' );
    like( slurp("$d/tmp/release-gate/0.1.1/receipt"), qr/^sha=$sha2$/m, 'and the receipt is the new commit\'s' );

    ( $rc, $out ) = gate_main( $d, '--beta' );
    is( calls($d), 3, 'another channel is another gate' );
    like( slurp("$d/calls"), qr/^ARGS gate 0\.1\.1 --commit $sha2 --beta$/m, 'with the channel passed on' );
};

subtest 'a tree still stamped for the last release is gated for real' => sub {
    my $d = repo( stamp => '0.1.0' );
    my ( $rc, $out ) = gate_main($d);
    is( $rc, 0, 'exit 0' ) or diag($out);
    like( slurp("$d/calls"), qr/^ARGS gate 0\.1\.1 --commit [0-9a-f]{40}$/m,
        'release.sh gate, with no rehearsal - the gate writes the material itself' );
    unlike( $out,                           qr/rehears/i, 'and nothing says rehearsal' );
    unlike( slurp("$d/tools/gate-main.sh"), qr/rehears/i, 'gate-main.sh has no rehearsal left in it' );
};

subtest 'a receipt from a gate that did not test the release material is gated again' => sub {
    my $d = repo();
    gate_main($d);
    my $r = "$d/tmp/release-gate/0.1.1/receipt";
    my $t = slurp($r) =~ s/^material_tool=.*\n//mr;
    spit( $r, $t );
    my ( $rc, $out ) = gate_main($d);
    is( calls($d), 2, 'a receipt with no material_tool is not "already gated"' );
};

subtest 'the version is not guessed' => sub {
    my $d = repo( next => '0.2.0', stamp => '0.2.0' );
    my ( $rc, $out ) = gate_main($d);
    is( $rc, 2, 'NEXT_VERSION disagreeing with release.sh\'s proposal is refused' );
    like( $out, qr/NEXT_VERSION .* says 0\.2\.0; the patch after v0\.1\.0 is 0\.1\.1/, 'naming both' );
    is( calls($d), 0, 'and nothing ran' );
    ( $rc, $out ) = gate_main( $d, '--version', '0.2.0' );
    is( $rc, 0, 'a version given explicitly is used' ) or diag($out);
    like( slurp("$d/calls"), qr/^ARGS gate 0\.2\.0 /m, 'as given' );

    my $b = repo();
    git( $b, 'tag', 'v0.1.1' );
    ( $rc, $out ) = gate_main($b);
    is( $rc, 2, 'a version already tagged is refused' );
    like( $out, qr/v0\.1\.1 is already tagged/, 'as burned' );
};

subtest 'a failed gate fails, and shows why' => sub {
    my $d = repo();
    local $ENV{STANDIN_FAIL} = 1;
    my ( $rc, $out ) = gate_main($d);
    is( $rc, 1, 'exit 1' );
    like( $out, qr/the gate FAILED/,       'says so' );
    like( $out, qr/the suite failed here/, 'with the end of the log' );
};

subtest 'one run at a time' => sub {
    my $d = repo();
    make_path("$d/tmp/release-gate");
    open my $lk, '>', "$d/tmp/release-gate/.gate-main.lock" or die $!;
    flock( $lk, LOCK_EX | LOCK_NB ) or die 'cannot take the lock';
    my ( $rc, $out ) = gate_main($d);
    is( $rc, 2, 'a second run is refused while the lock is held' );
    like( $out, qr/another gate-main run holds/, 'saying why' );
    is( calls($d), 0, 'and nothing ran' );
    close $lk;
};

done_testing();
