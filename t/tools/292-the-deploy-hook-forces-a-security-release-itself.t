#!/usr/bin/perl
# SM1315 (ruling 45): THE DEPLOY HOOK PASSES --force-security ITSELF.
#
# 0.16.2 declared itself security-critical, and the deploy hook ran the Hestia
# updater with its usual flags, so the updater scoped the release by each
# site's update_channel and the stable sites never got it; the operator pushed
# it to them by hand with the updater's --force-security. The hook now reads
# the release's own manifest, from the tarball it deploys, and adds the flag
# when it declares "security_critical": true. A missing or false key, or a
# manifest that cannot be read, adds nothing.
#
# DRIVEN, as t/tools/54 drives it: the real script is sourced, only the
# transport (scp, ssh) is stubbed, and the updater command line the hook would
# run on the host is recorded. The tarballs are real ones, laid out as
# release.sh packs them (lazysite-X.Y.Z/release-manifest.json).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_child);

my $root   = repo_root();
my $script = "$root/tools/lazysite-deploy.sh";
plan skip_all => "no $script" unless -f $script;

sub spit { my ( $p, $t ) = @_; open my $f, '>', $p or die "$p: $!"; print {$f} $t; close $f }
sub slurp { open my $f, '<', $_[0] or return ''; local $/; my $t = <$f>; close $f; $t }

# A dist holding lazysite-$ver.tar.gz whose manifest is $manifest (undef: the
# tarball has no manifest at all).
sub dist_with {
    my ( $ver, $manifest ) = @_;
    my $dir = tempdir( CLEANUP => 1 );
    my $src = "$dir/src/lazysite-$ver";
    make_path( $src, "$dir/dist" );
    spit( "$src/VERSION", "$ver\n" );
    spit( "$src/release-manifest.json", $manifest ) if defined $manifest;
    my $r = run_child( [ 'tar', '-czf', "$dir/dist/lazysite-$ver.tar.gz", '-C', "$dir/src", "lazysite-$ver" ],
        stderr => 'merge' );
    die "tar: $r->{out}" if $r->{status};
    return $dir;
}

# Source the hook, stub the transport, run $call; return the recorded ssh
# command lines and everything the hook printed.
sub hook {
    my ( $dir, $call, %env ) = @_;
    # _timeout: run the hook under timeout(1), for the watch loop, which never returns.
    my @limit = defined $env{_timeout} ? ( 'timeout', delete $env{_timeout} ) : ();
    my $log = "$dir/ssh.log";
    spit( "$dir/h.sh", <<"SH" );
set -u
export LAZYSITE_DIST=$dir/dist
export LAZYSITE_HOST=stub-host
export LAZYSITE_POLL=1
. "$script"
set +e
mount_ok() { return 0; }
scp() { return 0; }
ssh() { printf '%s\\n' "\$*" >> "$log"; return 0; }
$call
SH
    local @ENV{ keys %env } = values %env;
    my $r = run_child( [ @limit, 'bash', "$dir/h.sh" ], stderr => 'merge' );
    my ($updater) = grep { /update-all/ } split /\n/, slurp($log);
    return ( $updater // '', $r->{out} );
}

my %MANIFEST = (
    true  => qq({"version":"9.9.9","channel":"stable","security_critical":true}\n),
    absent => qq({"version":"9.9.9","channel":"stable"}\n),
    false => qq({"version":"9.9.9","channel":"stable","security_critical":false}\n),
);

subtest 'a release that declares security_critical is deployed with --force-security' => sub {
    my ( $cmd, $out ) = hook( dist_with( '9.9.9', $MANIFEST{true} ), 'deploy 9.9.9' );
    like( $cmd, qr/lazysite-hestia-update-all\.sh .*--force-security/, 'the updater is run with --force-security' )
        or diag $out;
    like( $out, qr/=== Deploying 9\.9\.9 -> stub-host \([^)]*--force-security[^)]*\) ===/, 'and the deploy line says so' );
    like( $cmd, qr/--reapply-acls/, 'beside the flags it already passed' );
};

for my $state (qw(absent false)) {
    subtest "a manifest with security_critical $state adds no flag" => sub {
        my ( $cmd, $out ) = hook( dist_with( '9.9.9', $MANIFEST{$state} ), 'deploy 9.9.9' );
        like( $cmd, qr/lazysite-hestia-update-all\.sh/, 'the updater is run' ) or diag $out;
        unlike( $cmd, qr/--force-security/, 'without --force-security' );
        unlike( $out, qr/no readable release-manifest/, 'and no warning: the manifest was read' );
    };
}

subtest 'a manifest that cannot be read adds no flag, and says so' => sub {
    for my $case ( [ 'no manifest in the tarball', undef ], [ 'a manifest that is not JSON', "{not json\n" ] ) {
        my ( $name, $m ) = @$case;
        my ( $cmd, $out ) = hook( dist_with( '9.9.9', $m ), 'deploy 9.9.9' );
        like( $cmd, qr/lazysite-hestia-update-all\.sh/, "$name: the updater is run" ) or diag $out;
        unlike( $cmd, qr/--force-security/, "$name: without --force-security" );
        like( $out, qr/9\.9\.9: no readable release-manifest\.json in .*; deploying without --force-security/,
            "$name: and the hook says it could not read the declaration" );
    }
};

subtest 'an operator who gives --force-security too gets it once' => sub {
    my ( $cmd, $out ) = hook( dist_with( '9.9.9', $MANIFEST{true} ), 'deploy 9.9.9',
        LAZYSITE_DEPLOY_FLAGS => '--force-security' );
    my $n = () = $cmd =~ /--force-security/g;
    is( $n, 1, 'the flag appears once' ) or diag $cmd;
};

# The flag changes which SITES the updater takes in, never which VERSIONS the
# watcher deploys: a security release at the baseline is still not deployed.
subtest 'the watcher still deploys only a strictly higher version' => sub {
    my $dir = dist_with( '9.9.9', $MANIFEST{true} );
    my ( $cmd, $out ) = hook( $dir, 'watch_and_deploy 9.9.9', _timeout => 3 );
    is( $cmd, '', 'a security-critical 9.9.9 at baseline 9.9.9 is not deployed' ) or diag $out;
    ( $cmd, $out ) = hook( $dir, 'watch_and_deploy 9.9.8', _timeout => 4 );
    like( $cmd, qr/--force-security/, 'CONTROL: from baseline 9.9.8 it is, with the flag' ) or diag $out;
};

done_testing();
