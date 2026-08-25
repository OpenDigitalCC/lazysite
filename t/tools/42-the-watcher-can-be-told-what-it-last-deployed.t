#!/usr/bin/perl
# SM595: a release that landed while the watcher was DOWN used to be absorbed.
#
# The baseline is normally the highest version already in dist at startup, and
# the watcher only deploys something strictly greater - so the release sitting
# there when it starts is the baseline and can never deploy. `--baseline X.Y.Z`
# states what was actually deployed instead.
#
# The behaviour half of this file runs the real watcher against a fake dist,
# with mount_ok/deploy/tarball_ready stubbed - the parts that would touch a
# remote host. The DETECTED case is the control: the same tree, the same
# tarballs, no --baseline, and nothing deploys. Without that control the given
# case would only prove that a deploy can happen at all.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $script = File::Spec->catfile( repo_root(), 'tools', 'lazysite-deploy.sh' );
ok( -f $script, 'the deploy watcher is where the manifest says it is' );

# --- argument handling -------------------------------------------------------
# Deliberately with NO LAZYSITE_HOST/LAZYSITE_DIST: asking for help must not
# require having configured the watcher first.
{
    local %ENV = ( %ENV, PATH => $ENV{PATH} );
    delete local $ENV{LAZYSITE_HOST};
    delete local $ENV{LAZYSITE_DIST};

    my $help = qx{bash \Q$script\E --help 2>&1};
    is( $? >> 8, 0, '--help exits 0 without any configuration' );
    like( $help, qr/^Usage: lazysite-deploy\.sh/m, '--help prints the usage' );
    like( $help, qr/--baseline/, '--help documents --baseline' );

    is( system( 'bash', $script ) >> 8, 2,
        'a bare run still refuses without LAZYSITE_HOST/LAZYSITE_DIST' );
}

{
    local $ENV{LAZYSITE_HOST} = 'example.test';
    local $ENV{LAZYSITE_DIST} = '/nonexistent';

    for my $bad ( '0.10.x', q{}, 'abc', '1.2.', '.1.2', '0.10.31-rc1' ) {
        is( system( 'bash', $script, '--baseline', $bad ) >> 8, 2,
            "--baseline '$bad' is refused" );
    }
    is( system( 'bash', $script, '--baseline' ) >> 8, 2,
        '--baseline with no value is refused' );
    is( system( 'bash', $script, '--nope' ) >> 8, 2, 'an unknown option is refused' );
    is( system( 'bash', $script, '--baseline=0.10.x' ) >> 8, 2,
        '--baseline=VALUE is validated the same way' );
}

# --- behaviour ---------------------------------------------------------------
my $dist = tempdir( CLEANUP => 1 );
for my $v (qw(0.10.31 0.10.32)) {
    for my $ext ( '', '.sha256' ) {
        open my $fh, '>', "$dist/lazysite-$v.tar.gz$ext" or die $!;
        print {$fh} "x\n";
        close $fh;
    }
}

# The harness SOURCES the watcher (so the main block does not run), replaces the
# three things that would reach a real host, and drives the REAL argument
# parser - so the command line under test is the one an operator types.
my $harness = "$dist/harness.sh";
open my $hf, '>', $harness or die $!;
print {$hf} <<"SH";
set -u
. "$script"
mount_ok()      { return 0; }
tarball_ready() { return 0; }
deploy()        { echo "DEPLOYED \$1"; return 0; }
parse_args "\$@"
watch_and_deploy "\$BASELINE"
SH
close $hf;

my %env = ( LAZYSITE_HOST => 'example.test', LAZYSITE_DIST => $dist, LAZYSITE_POLL => 1 );

{
    local @ENV{ keys %env } = values %env;

    # CONTROL: no --baseline. 0.10.32 is already in dist, so it IS the baseline
    # and must not deploy - this is the defect SM595 describes.
    my $detected = qx{timeout 3 bash \Q$harness\E 2>&1};
    like( $detected, qr/baseline: 0\.10\.32, detected/,
        'without --baseline the watcher takes 0.10.32 from dist' );
    unlike( $detected, qr/DEPLOYED/,
        'CONTROL: a release already in dist is absorbed, never deployed' );

    # The fix: state what was actually deployed, and the newer one catches up.
    my $given = qx{timeout 10 bash \Q$harness\E --baseline 0.10.31 2>&1};
    like( $given, qr/baseline: 0\.10\.31, given/,
        'the startup line says the baseline was given, not detected' );
    like( $given, qr/0\.10\.32 is already in dist and is newer/,
        'it says the catch-up is deliberate before doing it' );
    like( $given, qr/DEPLOYED 0\.10\.32/,
        '--baseline 0.10.31 deploys the 0.10.32 that was already sitting there' );
}

done_testing();
