#!/usr/bin/perl
# SM139 increment 3: fleet channel/policy behaviour of the `lazysite` CLI.
# update_policy gating of `upgrade --all` (manual = skipped, auto = upgraded
# when the channel accepts, per install.pl's existing exit-3 gate), --force
# overriding policy, --force-security accepted only when the payload manifest
# declares "security_critical": true (build-manifest.pl --security-critical),
# and the `sites` listing. Uses LAZYSITE_REGISTRY_DIR + the repo as payload;
# no root needed.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP   ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root repo_manifest_guard);

my $ROOT     = repo_root();
my $CLI      = "$ROOT/tools/lazysite-cli.pl";
# SM269 phase 1: the guard OWNS the shared repo-root manifest - it locks,
# builds if absent, and removes at scope end only if it built it. Six tests
# used to carry their own copy of that lifecycle, which is what kept racing.
my $MF_GUARD = repo_manifest_guard();

my $MANIFEST = "$ROOT/release-manifest.json";

die "lazysite-cli.pl not found at $CLI" unless -f $CLI;

# This suite rebuilds the repo-root release manifest with specific flags
# (channel, --security-critical), so snapshot whatever is there and put it
# back (or remove ours) when done - the same courtesy as t/tools/28-cli.t.
my $ORIG_MANIFEST = -f $MANIFEST ? slurp_raw($MANIFEST) : undef;


sub build_manifest {
    my (@flags) = @_;
    system( $^X, "$ROOT/tools/build-manifest.pl", @flags ) == 0
        or die "failed to build release-manifest.json (@flags)";
    return;
}

# Run the CLI; returns (exit_code, combined_output). %env entries are set
# for the child only.
sub run_cli {
    my ( $env, @args ) = @_;
    local %ENV = %ENV;
    delete $ENV{LAZYSITE_CLI_FAKE_ROOT};
    delete $ENV{LAZYSITE_REGISTRY_DIR};
    $ENV{$_} = $env->{$_} for keys %$env;
    my $cmd = join ' ', map { quotemeta } $^X, $CLI, @args;
    my $out = `$cmd 2>&1`;
    return ( $? >> 8, $out );
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or return '';
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

sub slurp_raw {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!";
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

# The installed version a site reports (from .install-state.json).
sub state_version {
    my ($docroot) = @_;
    my $s = eval { JSON::PP::decode_json( slurp_raw("$docroot/lazysite/.install-state.json") ) };
    return ref $s eq 'HASH' ? ( $s->{version} // '' ) : '';
}

# Rewrite a site's recorded version so the next install run is an UPGRADE
# (mode is gated on state-version != manifest-version); file SHAs stay real.
sub doctor_version {
    my ( $docroot, $version ) = @_;
    my $path = "$docroot/lazysite/.install-state.json";
    my $s    = JSON::PP::decode_json( slurp_raw($path) );
    $s->{version} = $version;
    open my $fh, '>:raw', $path or die "cannot write $path: $!";
    print {$fh} JSON::PP->new->utf8(1)->canonical(1)->encode($s);
    close $fh;
    return;
}

my $ME = getpwuid($>) // "uid$>";
chomp( my $VERSION = slurp("$ROOT/VERSION") );

# Payload manifest: default build = channel edge, NOT security-critical.
build_manifest();

my $dir = tempdir( 'lazysite-cli-fleet-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
my $reg = "$dir/reg";
make_path($reg);
my %env = ( LAZYSITE_REGISTRY_DIR => $reg );

# Three registered sites spanning the policy x channel matrix:
#   alpha   - update_policy auto,   update_channel edge   (fleet-upgradable)
#   bravo   - update_policy manual, update_channel stable (operator-only)
#   charlie - update_policy auto,   update_channel stable (channel-gated)
my %site;
for my $s (
    [ 'alpha.example', '--policy', 'auto', '--channel', 'edge' ],
    ['bravo.example'],
    [ 'charlie.example', '--policy', 'auto' ],
    )
{
    my ( $name,    @flags )  = @$s;
    my ( $docroot, $cgibin ) = ( "$dir/$name/site", "$dir/$name/cgi-bin" );
    make_path( $docroot, $cgibin );
    my ( $rc, $out ) = run_cli( \%env, 'provision', '--docroot', $docroot,
        '--cgibin', $cgibin, '--domain', $name, @flags );
    die "provision $name failed:\n$out" unless $rc == 0;
    $site{$name} = { docroot => $docroot, cgibin => $cgibin };
}

subtest 'provision records policy in conf and registry' => sub {
    like( slurp("$site{'alpha.example'}{docroot}/lazysite/lazysite.conf"),
        qr/^update_policy:\s*auto$/m, '--policy auto lands in lazysite.conf' );
    like( slurp("$site{'alpha.example'}{docroot}/lazysite/lazysite.conf"),
        qr/^update_channel:\s*edge$/m, '--channel edge lands in lazysite.conf' );
    like( slurp("$reg/alpha.example"), qr/^policy=auto$/m, 'registry policy=auto' );
    like( slurp("$reg/bravo.example"), qr/^policy=manual$/m, 'registry default policy=manual' );
    like( slurp("$reg/charlie.example"), qr/^policy=auto$/m, 'registry policy=auto (charlie)' );

    my ( $rc, $out ) = run_cli( \%env, 'provision', '--docroot', "$dir/x",
        '--cgibin', "$dir/y", '--policy', 'sometimes' );
    is( $rc, 1, 'provision --policy sometimes: rejected' );
    like( $out, qr/--policy must be 'auto' or 'manual'/, 'rejection names the values' );
};

subtest 'upgrade --all honours policy and channel' => sub {
    doctor_version( $site{$_}{docroot}, '0.0.1' ) for keys %site;

    my ( $rc, $out ) = run_cli( \%env, 'upgrade', '--all' );
    is( $rc, 0, 'upgrade --all: exit 0 (skips are not failures)' ) or diag($out);
    is( state_version( $site{'alpha.example'}{docroot} ),
        $VERSION, 'alpha (auto + edge): upgraded' );
    is( state_version( $site{'bravo.example'}{docroot} ),
        '0.0.1', 'bravo (manual): untouched' );
    like( $out, qr/bravo\.example: update_policy is 'manual' - skipped/,
        'bravo skip logged per site' );
    is( state_version( $site{'charlie.example'}{docroot} ),
        '0.0.1', 'charlie (auto + stable vs edge payload): untouched' );
    like( $out, qr/Upgrade SKIPPED/, "charlie's channel skip comes from install.pl" );
    like( $out, qr/charlie\.example: skipped by its update_channel/,
        'charlie skip logged per site' );
    like( $out, qr/upgraded 1 site\(s\), skipped 2/, 'summary counts skips' );
};

subtest '--force overrides policy (and channel)' => sub {
    doctor_version( $site{$_}{docroot}, '0.0.1' ) for keys %site;

    my ( $rc, $out ) = run_cli( \%env, 'upgrade', '--all', '--force' );
    is( $rc, 0, 'upgrade --all --force: exit 0' ) or diag($out);
    is( state_version( $site{$_}{docroot} ), $VERSION, "$_ upgraded under --force" )
        for sort keys %site;
    like( $out, qr/upgraded 3 site\(s\)/, 'summary: all three upgraded' );
};

subtest '--force-security refused without a security-critical manifest' => sub {
    doctor_version( $site{'bravo.example'}{docroot}, '0.0.1' );

    my ( $rc, $out ) = run_cli( \%env, 'upgrade', '--all', '--force-security' );
    is( $rc, 1, 'upgrade --all --force-security: refused' );
    like( $out, qr/--force-security refused/,  'refusal is explicit' );
    like( $out, qr/does not declare/,          'names the missing declaration' );
    like( $out, qr/"security_critical": true/, 'names the manifest field' );
    unlike( $out, qr/==/, 'no site was visited' );
    is( state_version( $site{'bravo.example'}{docroot} ),
        '0.0.1', 'bravo untouched by the refused run' );
};

subtest '--force-security with a security-critical payload' => sub {
    build_manifest('--security-critical');
    like( slurp_raw($MANIFEST), qr/"security_critical"\s*:\s*true/,
        'build-manifest --security-critical stamps the manifest' );

    my ( $rc, $out ) = run_cli( \%env, 'version' );
    like( $out, qr/security-critical/, 'version verb surfaces the declaration' );

    doctor_version( $site{$_}{docroot}, '0.0.1' ) for keys %site;
    ( $rc, $out ) = run_cli( \%env, 'upgrade', '--all', '--force-security' );
    is( $rc, 0, 'upgrade --all --force-security: exit 0' ) or diag($out);
    like( $out, qr/declares security_critical: overriding channel and policy/,
        'override announced' );
    is( state_version( $site{$_}{docroot} ),
        $VERSION, "$_ upgraded despite policy/channel" )
        for sort keys %site;
    like( $out, qr/upgraded 3 site\(s\)/, 'summary: all three upgraded' );

    build_manifest();    # back to a plain edge manifest for the verbs below
};

subtest 'sites listing' => sub {
    my ( $rc, $out ) = run_cli( \%env, 'sites' );
    is( $rc, 0, 'sites: exit 0' ) or diag($out);
    like( $out, qr/^SITE\s+OWNER\s+CHANNEL\s+POLICY\s+VERSION\s+DOCROOT/,
        'header row' );
    like( $out,
        qr/^alpha\.example\s+\Q$ME\E\s+edge\s+auto\s+\Q$VERSION\E\s+\Q$site{'alpha.example'}{docroot}\E$/mx,
        'alpha row: conf channel/policy + installed version + docroot' );
    like( $out, qr/^bravo\.example\s+\Q$ME\E\s+stable\s+manual\s+\Q$VERSION\E\s+/mx,
        'bravo row: seeded stable channel, default manual policy' );

    ( $rc, $out ) = run_cli( { LAZYSITE_REGISTRY_DIR => "$dir/empty-reg" }, 'sites' );
    is( $rc, 0, 'sites with empty registry: exit 0' );
    like( $out, qr/no sites registered/, 'empty registry is said plainly' );
};

done_testing();
