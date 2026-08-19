#!/usr/bin/perl
# SM379: the watcher must not exit when a deploy finishes.
#
# It did, and it exited with the updater's OWN status - which is what made it
# invisible. Status 2 is SM344's "rollout succeeded, the fleet has findings": a
# SUCCESSFUL deploy. So the watcher deployed, printed the success text, and
# died. From outside that reads as "it deployed once and stopped", because that
# is exactly what it did, and 0.10.14 then sat in dist with nothing watching.
#
# THE MECHANISM IS A SHELL OPTION, NOT A FUNCTION-LOCAL ONE. deploy() ended
# `set +e; ssh ...; rc=$?; set -e; return "$rc"`, and that final `set -e` takes
# effect immediately - so the function returned non-zero with -e freshly
# re-enabled, and the caller's own `set +e` had been undone from underneath it.
#
# DRIVEN, NOT READ. The defect is entirely in what the shell does with an
# option, so a test that grepped for the fixed source would prove nothing about
# behaviour. This sources the real script, stubs only the transport, and runs
# the real deploy() and watch loop.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root   = repo_root();
my $script = "$root/tools/lazysite-deploy.sh";
plan skip_all => "no $script" unless -f $script;

chomp( my $bash = `sh -c 'command -v bash' 2>/dev/null` );
plan skip_all => 'bash not installed' unless length $bash && -x $bash;

# Run the watcher with the transport stubbed and the updater returning $rc.
# Returns 'survived' or "exited N".
sub run_with {
    my ($rc) = @_;
    my $dir  = tempdir( CLEANUP => 1 );
    my $dist = "$dir/dist";
    mkdir $dist;
    for my $v (qw(1.0.0)) {
        system("printf x | gzip > \Q$dist/lazysite-$v.tar.gz\E");
    }

    my $harness = "$dir/h.sh";
    open my $fh, '>', $harness or die $!;
    print {$fh} <<"SH";
set +e
export LAZYSITE_DIST=$dist
export LAZYSITE_HOST=stub-host
export LAZYSITE_POLL=1
export STUB_RC=$rc
source $script
set +e
mount_ok() { return 0; }
scp() { return 0; }
ssh() { case "\$*" in *update-all*) return "\$STUB_RC" ;; *) return 0 ;; esac; }
watch_and_deploy >/dev/null 2>&1 &
W=\$!
sleep 2
printf x | gzip > $dist/lazysite-1.0.1.tar.gz
sleep 4
if kill -0 "\$W" 2>/dev/null; then echo survived; kill "\$W" 2>/dev/null
else wait "\$W"; echo "exited \$?"; fi
SH
    close $fh;
    chomp( my $out = `\Q$bash\E \Q$harness\E 2>/dev/null` );
    return $out;
}

subtest 'a clean deploy leaves the watcher running' => sub {
    is( run_with(0), 'survived', 'rollout clean (status 0)' );
};

subtest 'a deploy with FLEET FINDINGS leaves the watcher running' => sub {
    # This is the one that bit. Status 2 means the rollout SUCCEEDED.
    is( run_with(2), 'survived', 'rollout succeeded, fleet has findings (status 2)' )
        or diag( 'The watcher exited on a SUCCESSFUL deploy, with the success '
            . "code as its own exit status. That is why it looked like it had\n"
            . 'deployed once and stopped, and why the next release sat in dist '
            . 'with nothing watching it.' );
};

subtest 'a FAILED deploy leaves the watcher running too' => sub {
    is( run_with(9), 'survived', 'rollout failed (status 9)' )
        or diag( 'The caller has a failure arm - "skipping (bump again to '
            . 'retry)" - which was UNREACHABLE: any non-zero status killed the '
            . 'shell at the call, so nothing ever reached the case. A message '
            . 'telling an operator the watcher is still going could only be '
            . 'printed by a watcher that was not.' );
};

subtest 'and no option juggling is left to get wrong' => sub {
    my $src = do { open my $fh, '<', $script or die $!; local $/; <$fh> };
    my ($body) = $src =~ /\ndeploy\(\) \{(.*?)\n\}\n/s;
    ok( $body, 'deploy() is present' ) or return;
    unlike( $body, qr/^\s*set [+-]e\s*$/m,
        'deploy() does not touch the -e option' )
        or diag( 'set -e is global. Toggling it inside a function changes it '
            . 'for the caller, which is the whole defect.' );
};

done_testing();
