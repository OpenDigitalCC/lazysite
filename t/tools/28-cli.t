#!/usr/bin/perl
# SM139: tests for the `lazysite` host CLI (tools/lazysite-cli.pl) - verb
# dispatch, the no-root refusal (via the TEST-ONLY LAZYSITE_CLI_FAKE_ROOT
# override), a provision + upgrade round-trip against a tempdir using the
# repo as the payload, registry emission/tolerance, and the version verb.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $ROOT     = repo_root();
my $CLI      = "$ROOT/tools/lazysite-cli.pl";
my $MANIFEST = "$ROOT/release-manifest.json";

die "lazysite-cli.pl not found at $CLI" unless -f $CLI;

# SM065: release-manifest.json is generated, not tracked. install.pl (which
# provision/upgrade wrap) needs one beside it; build on demand and clean up
# only if we created it (same pattern as t/tools/03-install-pl.t).
my $MANIFEST_CREATED_BY_US = 0;
unless ( -f $MANIFEST ) {
    system( $^X, "$ROOT/tools/build-manifest.pl" ) == 0
        or die "failed to build release-manifest.json";
    $MANIFEST_CREATED_BY_US = 1;
}
END {
    if ( $MANIFEST_CREATED_BY_US && -f $MANIFEST ) {
        unlink $MANIFEST;
    }
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

my $ME = getpwuid($>) // "uid$>";

# --- verb dispatch ----------------------------------------------------------
subtest 'dispatch and usage' => sub {
    my ( $rc, $out ) = run_cli( {} );
    is( $rc, 2, 'no verb: exit 2' );
    like( $out, qr/Usage: lazysite VERB/, 'no verb: usage shown' );

    ( $rc, $out ) = run_cli( {}, 'help' );
    is( $rc, 0, 'help: exit 0' );
    like( $out, qr/provision --docroot/, 'help lists provision' );

    ( $rc, $out ) = run_cli( {}, 'frobnicate' );
    is( $rc, 2, 'unknown verb: exit 2' );
    like( $out, qr/unknown verb 'frobnicate'/, 'unknown verb named' );

    # dev passthrough reaches the dev server's own --help
    ( $rc, $out ) = run_cli( {}, 'dev', '--help' );
    is( $rc, 0, 'dev --help: exit 0' );
    like( $out, qr/lazysite dev server/, 'dev dispatches to lazysite-server.pl' );

    # check passthrough reaches lazysite-check.pl's own --help
    ( $rc, $out ) = run_cli( {}, 'check', '--help' );
    like( $out, qr/permissions doctor/, 'check dispatches to lazysite-check.pl' );
};

# --- version verb ------------------------------------------------------------
subtest 'version verb' => sub {
    chomp( my $version = slurp("$ROOT/VERSION") );
    my ( $rc, $out ) = run_cli( {}, 'version' );
    is( $rc, 0, 'version: exit 0' );
    like( $out, qr/\Qlazysite $version\E/, 'payload VERSION reported' );
    like( $out, qr/channel: \S+/,          'channel reported' );
};

# --- no-root refusal (LAZYSITE_CLI_FAKE_ROOT is the documented test-only
# override; it only ever makes the CLI more restrictive) ----------------------
subtest 'no-root refusal' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    for my $args ( [ 'provision', '--docroot', "$dir/s", '--cgibin', "$dir/c" ],
        [ 'upgrade', '--docroot', "$dir/s" ] )
    {
        my ( $rc, $out ) = run_cli( { LAZYSITE_CLI_FAKE_ROOT => 1 }, @$args );
        is( $rc, 1, "$args->[0] as (fake) root: refused" );
        like( $out, qr/refusing to run '$args->[0]' as root/, 'refusal message' );
        like( $out, qr/sudo -u SITEUSER/, 'points at the site-user path' );
        ok( !-e "$dir/s/lazysite", 'nothing was installed' );
    }
};

# --- provision + upgrade round-trip, registry emission ------------------------
subtest 'provision + upgrade round-trip' => sub {
    my $dir = tempdir( 'lazysite-cli-test-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    my ( $docroot, $cgibin, $reg ) = ( "$dir/site", "$dir/cgi-bin", "$dir/reg" );
    make_path( $docroot, $cgibin, $reg );

    my ( $rc, $out ) = run_cli( { LAZYSITE_REGISTRY_DIR => $reg },
        'provision', '--docroot', $docroot, '--cgibin', $cgibin,
        '--domain', 'cli-test.example', '--channel', 'stable' );
    is( $rc, 0, 'provision: exit 0' ) or diag($out);
    ok( -f "$cgibin/lazysite-processor.pl", 'processor installed to cgi-bin' );
    ok( -f "$docroot/lazysite/.install-state.json", 'install state written' );
    like( slurp("$docroot/lazysite/lazysite.conf"),
        qr/^update_channel:\s*stable/m, '--channel pinned update_channel' );

    my $entry = "$reg/cli-test.example";
    ok( -f $entry, 'registry entry written' ) or diag($out);
    my $body = slurp($entry);
    like( $body, qr/^docroot=\Q$docroot\E$/m, 'registry docroot=' );
    like( $body, qr/^cgibin=\Q$cgibin\E$/m,   'registry cgibin=' );
    like( $body, qr/^owner=\Q$ME\E$/m,        'registry owner=' );
    like( $body, qr/^channel=stable$/m,       'registry channel=' );

    # Same-version upgrade via the registry (no --cgibin needed): install.pl
    # reports up-to-date and exits 0.
    ( $rc, $out ) = run_cli( { LAZYSITE_REGISTRY_DIR => $reg },
        'upgrade', '--docroot', $docroot, '--force' );
    is( $rc, 0, 'upgrade --docroot (cgibin from registry): exit 0' ) or diag($out);

    # upgrade --all (non-root, our own site) walks the registry.
    ( $rc, $out ) = run_cli( { LAZYSITE_REGISTRY_DIR => $reg },
        'upgrade', '--all', '--force' );
    is( $rc, 0, 'upgrade --all: exit 0' ) or diag($out);
    like( $out, qr/== cli-test\.example:/, 'upgrade --all names the site' );
    like( $out, qr/upgraded 1 site/,       'upgrade --all summary' );

    # users passthrough against the provisioned site.
    ( $rc, $out ) = run_cli( {}, 'users', '--docroot', $docroot, 'list' );
    is( $rc, 0, 'users list on provisioned site: exit 0' ) or diag($out);
};

# --- registry: unwritable dir never fails provisioning ------------------------
subtest 'registry unwritable: provision still succeeds' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my ( $docroot, $cgibin ) = ( "$dir/site", "$dir/cgi-bin" );
    make_path( $docroot, $cgibin );

    my ( $rc, $out ) = run_cli( { LAZYSITE_REGISTRY_DIR => "$dir/no/such/dir" },
        'provision', '--docroot', $docroot, '--cgibin', $cgibin,
        '--domain', 'unreg.example' );
    is( $rc, 0, 'provision: exit 0 despite unwritable registry' ) or diag($out);
    like( $out, qr/registry not writable/, 'explains the registry situation' );
    like( $out, qr/unreg\.example containing:/, 'names the file to drop in' );
    like( $out, qr/^\s+docroot=\Q$docroot\E$/m, 'prints the entry body' );
    ok( -f "$cgibin/lazysite-processor.pl", 'site was still provisioned' );
};

# --- registry read tolerance + --all ownership refusal -------------------------
subtest 'registry tolerance and --all ownership' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my ( $docroot, $cgibin, $reg ) = ( "$dir/site", "$dir/cgi-bin", "$dir/reg" );
    make_path( $docroot, $cgibin, $reg );

    my ( $rc, $out ) = run_cli( { LAZYSITE_REGISTRY_DIR => $reg },
        'provision', '--docroot', $docroot, '--cgibin', $cgibin,
        '--domain', 'good.example' );
    is( $rc, 0, 'provision good site' ) or diag($out);

    # Garbled + docroot-less entries are skipped with a warning, not fatal.
    open my $g, '>', "$reg/garbled.example" or die $!;
    print {$g} "this is not ini\n=====\n";
    close $g;
    ( $rc, $out ) = run_cli( { LAZYSITE_REGISTRY_DIR => $reg },
        'upgrade', '--all', '--force' );
    is( $rc, 0, 'upgrade --all tolerates a garbled entry' ) or diag($out);
    like( $out, qr/'garbled\.example'.*skipped/, 'garbled entry warned + skipped' );
    like( $out, qr/upgraded 1 site/, 'good site still upgraded' );

    # A registered site owned by someone else refuses --all for a non-root
    # caller.
    open my $f, '>', "$reg/foreign.example" or die $!;
    print {$f} "docroot=$docroot\ncgibin=$cgibin\nowner=somebody-else\nchannel=edge\n";
    close $f;
    ( $rc, $out ) = run_cli( { LAZYSITE_REGISTRY_DIR => $reg },
        'upgrade', '--all' );
    is( $rc, 1, 'upgrade --all with a foreign site: refused for non-root' );
    like( $out, qr/foreign\.example/, 'refusal names the foreign site' );

    # Upgrade of a docroot with no registry entry and no --cgibin: helpful
    # failure.
    ( $rc, $out ) = run_cli( { LAZYSITE_REGISTRY_DIR => "$dir/empty" },
        'upgrade', '--docroot', $docroot );
    is( $rc, 1, 'upgrade without registry entry or --cgibin fails' );
    like( $out, qr/pass --cgibin/, 'failure explains the fix' );
};

# --- POD + man page (the deb ships lazysite.1 from gen-manpages.pl) ----------
subtest 'POD and man page generation' => sub {
    for my $s ( $CLI, "$ROOT/tools/lazysite-pool.pl" ) {
        my $out = `podchecker \Q$s\E 2>&1`;
        like( $out, qr/pod syntax OK/, 'POD valid: ' . ( $s =~ m{([^/]+)$} )[0] );
    }
    my $mandir = tempdir( CLEANUP => 1 );
    system( $^X, "$ROOT/tools/gen-manpages.pl", $mandir ) == 0
        or diag('gen-manpages.pl failed');
    ok( -s "$mandir/lazysite.1", 'gen-manpages.pl produces lazysite.1' );
};

done_testing();
