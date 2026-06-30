#!/usr/bin/perl
# D021c: tests for install.pl. Each subtest spins up a temp docroot
# and cgibin, runs install.pl against the live release-manifest.json
# at the repo root, and inspects the resulting filesystem.
#
# The release-manifest.json baseline is whatever's checked in. Tests
# avoid assumptions about exact file counts by using relative
# comparisons and spot-checks.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempdir);
use File::Basename qw(basename dirname);
use File::Copy qw();
use Digest::SHA qw(sha256_hex);
use JSON::PP qw(decode_json);
use FindBin;

my $ROOT = "$FindBin::Bin/../..";
my $INSTALL = "$ROOT/install.pl";
my $MANIFEST = "$ROOT/release-manifest.json";
my $BUILD_MF = "$ROOT/tools/build-manifest.pl";

die "install.pl not found at $INSTALL" unless -f $INSTALL;

# SM065: release-manifest.json is no longer tracked (it ships only
# in release tarballs). install.pl at the repo root needs a
# manifest alongside it to run. Generate one on demand so the test
# exercises a freshly-built catalogue against the current working
# tree.
#
# The file is gitignored, but if we create it during the test run
# we also delete it at END so rsync-based commit flows don't pick
# up a phantom "modified" manifest for a file that should be absent
# on main. Track whether WE built it so we don't nuke an operator's
# locally-generated copy.
my $MANIFEST_CREATED_BY_US = 0;
unless ( -f $MANIFEST ) {
    die "build-manifest.pl not found at $BUILD_MF" unless -f $BUILD_MF;
    system( $^X, $BUILD_MF ) == 0
        or die "failed to build release-manifest.json via $BUILD_MF";
    die "manifest build produced no file at $MANIFEST" unless -f $MANIFEST;
    $MANIFEST_CREATED_BY_US = 1;
}
END {
    if ( $MANIFEST_CREATED_BY_US && -f $MANIFEST ) {
        unlink $MANIFEST;
    }
}

sub fresh_docroot {
    my $dir = tempdir( 'lazysite-install-test-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    make_path("$dir/site");
    make_path("$dir/cgi-bin");
    return ( "$dir/site", "$dir/cgi-bin", $dir );
}

sub run_install {
    my @args = @_;
    my $cmd = join ' ', map { quotemeta } $^X, $INSTALL, @args;
    my $out = `$cmd 2>&1`;
    return ( $? >> 8, $out );
}

sub sha_file {
    my ($p) = @_;
    return '' unless -f $p;
    open my $fh, '<:raw', $p or return '';
    my $d = Digest::SHA->new('sha256');
    $d->addfile($fh);
    close $fh;
    return 'sha256:' . $d->hexdigest;
}

sub load_state {
    my ($docroot) = @_;
    my $path = "$docroot/lazysite/.install-state.json";
    return undef unless -f $path;
    open my $fh, '<:raw', $path or return undef;
    my $text = do { local $/; <$fh> };
    close $fh;
    return decode_json($text);
}

sub load_manifest {
    open my $fh, '<:raw', $MANIFEST or die $!;
    my $text = do { local $/; <$fh> };
    close $fh;
    return decode_json($text);
}

my $manifest = load_manifest();

# --- 1. Fresh install ---

subtest 'fresh install: manifest applied, state written, SHAs match' => sub {
    my ($docroot, $cgibin) = fresh_docroot();
    my ($rc, $out) = run_install(
        '--docroot', $docroot, '--cgibin', $cgibin,
    );
    is( $rc, 0, 'exit 0' ) or diag $out;

    ok( -f "$docroot/lazysite/.install-state.json", 'state file written' );
    my $state = load_state($docroot);
    is( $state->{schema_version}, '1', 'schema_version' );
    is( $state->{version}, $manifest->{version}, 'version matches manifest' );
    ok( scalar keys %{$state->{files}} > 50, 'state has many files' );

    # Spot-check a code file and a seed file
    my $proc = "$cgibin/lazysite-processor.pl";
    ok( -f $proc, 'processor installed' );
    is( $state->{files}{$proc}, sha_file($proc), 'processor SHA in state' );

    my $index = "$docroot/index.md";
    ok( -f $index, 'index.md installed' );
    is( $state->{files}{$index}, sha_file($index), 'index.md SHA in state' );
};

# Runtime dirs must be setgid + group-writable so the www-data CGI can write
# them (the auth dir is the one that broke "add user: Permission denied"). The
# file-install pass creates these dirs first, so install.pl must apply the
# declared runtime mode on a fresh install even though the dir already exists.
subtest 'fresh install: runtime dirs are setgid + group-writable' => sub {
    my ( $docroot, $cgibin ) = fresh_docroot();
    my ( $rc, $out ) = run_install( '--docroot', $docroot, '--cgibin', $cgibin );
    is( $rc, 0, 'exit 0' ) or diag $out;

    my %want = (
        'lazysite/auth'          => 02770,    # private: no world access
        'lazysite/cache'         => 02775,
        'lazysite/logs'          => 02775,
        'lazysite/manager/locks' => 02775,
        'lazysite/layouts'       => 02775,
    );
    for my $rel ( sort keys %want ) {
        my $got = ( stat "$docroot/$rel" )[2] & 07777;
        is( $got, $want{$rel}, sprintf( '%s is %04o (setgid + group-write)', $rel, $want{$rel} ) );
    }
    is( ( ( stat "$docroot/lazysite/auth" )[2] & 07 ), 0, 'auth dir has no world bits' );
};

# --- 2. Upgrade with no edits: all overwritten, state refreshed ---

subtest 'upgrade (same version), no edits: all overwritten, state refreshed' => sub {
    my ($docroot, $cgibin) = fresh_docroot();
    my ($rc1, undef) = run_install( '--docroot', $docroot, '--cgibin', $cgibin );
    is( $rc1, 0, 'fresh ok' );
    my $state1 = load_state($docroot);

    my ($rc2, $out2) = run_install( '--docroot', $docroot, '--cgibin', $cgibin );
    is( $rc2, 0, 'reinstall exit 0' ) or diag $out2;

    like( $out2, qr/Installed:\s*0/, 'nothing new installed' );
    like( $out2, qr/Overwrote:\s*\d+/, 'files overwrote' );
    like( $out2, qr/Preserved:\s*0/, 'nothing preserved' );
    like( $out2, qr/Removed:\s*0/, 'nothing removed' );
    like( $out2, qr/Backup:/, 'backup path shown' );

    my $state2 = load_state($docroot);
    is_deeply( [ sort keys %{$state2->{files}} ],
               [ sort keys %{$state1->{files}} ],
               'file set unchanged' );
};

# --- 3. Seed edited: preserve; code edited: overwrite ---

subtest 'seed edited preserved; code edited overwritten' => sub {
    my ($docroot, $cgibin) = fresh_docroot();
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );

    # Edit a seed file
    my $seed_path = "$docroot/contact.md";
    open my $sfh, '>>', $seed_path or die $!;
    print $sfh "\n# operator edit\n";
    close $sfh;
    my $seed_after_edit_sha = sha_file($seed_path);

    # Edit a code file
    my $code_path = "$cgibin/lazysite-processor.pl";
    open my $cfh, '>>', $code_path or die $!;
    print $cfh "\n# operator edit\n";
    close $cfh;

    my ($rc, $out) = run_install( '--docroot', $docroot, '--cgibin', $cgibin );
    is( $rc, 0, 'reinstall exit 0' ) or diag $out;

    like( $out, qr/Preserved:\s*1/, 'one preserved' );
    like( $out, qr/Overwrote:/, 'overwrote count' );
    like( $out, qr{- \Q$seed_path\E}, 'seed path listed as preserved' );

    is( sha_file($seed_path), $seed_after_edit_sha,
        'seed file disk content unchanged' );
    unlike( slurp($code_path), qr/# operator edit/,
        'code file overwritten (operator edit gone)' );
};

# --- 4. File removed from manifest (simulate by editing state) ---

subtest 'upgrade: unedited orphan removed; edited orphan preserved' => sub {
    my ($docroot, $cgibin) = fresh_docroot();
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );

    # Create two fake "previously installed" files and add them to state
    # so the next run sees them as "in stored but not in new manifest".
    my $state = load_state($docroot);
    my $unedited_orphan = "$docroot/unedited-orphan.md";
    my $edited_orphan   = "$docroot/edited-orphan.md";
    open my $f1, '>', $unedited_orphan or die $!;
    print $f1 "orphan content\n";
    close $f1;
    open my $f2, '>', $edited_orphan or die $!;
    print $f2 "original\n";
    close $f2;

    $state->{files}{$unedited_orphan} = sha_file($unedited_orphan);
    $state->{files}{$edited_orphan}   = sha_file($edited_orphan);

    open my $sfh, '>:raw', "$docroot/lazysite/.install-state.json" or die $!;
    print $sfh JSON::PP->new->canonical(1)->pretty(1)->encode($state);
    close $sfh;

    # Edit one of them so it no longer matches the state SHA
    open my $e, '>>', $edited_orphan or die $!;
    print $e "operator edit\n";
    close $e;

    my ($rc, $out) = run_install( '--docroot', $docroot, '--cgibin', $cgibin );
    is( $rc, 0, 'exit 0' ) or diag $out;

    ok( !-f $unedited_orphan, 'unedited orphan removed' );
    ok( -f $edited_orphan, 'edited orphan preserved' );
    like( $out, qr/orphan/i, 'orphan warning in output' );
};

# --- 5. Backup created on upgrade ---

subtest 'backup created, extracts, contains state file' => sub {
    my ($docroot, $cgibin) = fresh_docroot();
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );

    my @backups = glob("$docroot/lazysite/backups/lazysite-backup-*.tar.gz");
    is( scalar @backups, 1, 'one backup produced' );
    ok( -s $backups[0], 'backup non-empty' );

    my $peek = `tar tzf $backups[0] 2>&1`;
    like( $peek, qr/\.install-state\.json/, 'backup contains state file' );
    like( $peek, qr/index\.md/, 'backup contains a starter file' );
};

# --- 6. Retention: 4 runs with retention=3 -> oldest removed ---

subtest 'backup_retention: 3 keeps 3 most recent' => sub {
    my ($docroot, $cgibin) = fresh_docroot();
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );
    open my $fh, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
    print $fh "\nbackup_retention: 3\n";
    close $fh;

    for my $i ( 1 .. 4 ) {
        run_install( '--docroot', $docroot, '--cgibin', $cgibin );
        # Force distinct timestamps so backup filenames don't collide
        sleep 1 if $i < 4;
    }

    my @backups = glob("$docroot/lazysite/backups/lazysite-backup-*.tar.gz");
    is( scalar @backups, 3, '3 backups retained' );
};

subtest 'backup_retention: 0 keeps all' => sub {
    my ($docroot, $cgibin) = fresh_docroot();
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );
    open my $fh, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
    print $fh "\nbackup_retention: 0\n";
    close $fh;

    for my $i ( 1 .. 3 ) {
        run_install( '--docroot', $docroot, '--cgibin', $cgibin );
        sleep 1 if $i < 3;
    }

    my @backups = glob("$docroot/lazysite/backups/lazysite-backup-*.tar.gz");
    is( scalar @backups, 3, 'all 3 backups retained' );
};

# --- 7. Restore most recent ---

subtest 'restore most recent backup: files return to prior state' => sub {
    my ($docroot, $cgibin) = fresh_docroot();
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );

    # Snapshot starting content of a seed file
    my $seed = "$docroot/contact.md";
    my $original = slurp($seed);

    # Edit the seed (operator change)
    open my $e, '>', $seed or die $!;
    print $e "# operator's content\n";
    close $e;
    my $operator_content = slurp($seed);

    # Reinstall - preserves the seed, creates backup of this state
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );

    # Vandalise
    open my $v, '>', $seed or die $!;
    print $v "GARBAGE\n";
    close $v;

    # Restore most recent
    my ($rc, $out) = run_install( '--docroot', $docroot, '--restore' );
    is( $rc, 0, 'restore exit 0' ) or diag $out;

    is( slurp($seed), $operator_content, 'seed restored to operator-edited content' );
    like( $out, qr/Restore complete/, 'restore complete message' );
};

# --- 8. Restore specific backup ---

subtest 'restore --backup PATH: named tarball restored' => sub {
    my ($docroot, $cgibin) = fresh_docroot();
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );

    # Edit a seed, reinstall to back up the edited state
    my $seed = "$docroot/contact.md";
    open my $e, '>', $seed or die $!;
    print $e "# mark A\n";
    close $e;
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );

    my @backups = glob("$docroot/lazysite/backups/lazysite-backup-*.tar.gz");
    my $first_backup = $backups[0];

    # Change again, reinstall for a second backup
    open my $e2, '>', $seed or die $!;
    print $e2 "# mark B\n";
    close $e2;
    sleep 1;
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );

    # Restore the first (older) backup explicitly
    my ($rc, $out) = run_install(
        '--docroot', $docroot, '--restore', '--backup', $first_backup,
    );
    is( $rc, 0, 'restore exit 0' ) or diag $out;

    like( slurp($seed), qr/mark A/, 'seed restored to first-backup content' );
    unlike( slurp($seed), qr/mark B/, 'second-backup content not present' );
};

# --- 9. --list-backups ---

subtest '--list-backups shows expected output' => sub {
    my ($docroot, $cgibin) = fresh_docroot();
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );

    my ($rc, $out) = run_install( '--docroot', $docroot, '--list-backups' );
    is( $rc, 0, 'list-backups exit 0' ) or diag $out;
    like( $out, qr/lazysite-backup-/, 'backup file name shown' );
    like( $out, qr/Size/, 'header row' );
};

# --- 10. --dry-run makes no changes ---

subtest '--dry-run does not modify filesystem' => sub {
    my ($docroot, $cgibin) = fresh_docroot();

    my ($rc, $out) = run_install(
        '--docroot', $docroot, '--cgibin', $cgibin, '--dry-run',
    );
    is( $rc, 0, 'exit 0' ) or diag $out;
    like( $out, qr/no changes/, 'dry-run message in output' );

    ok( !-f "$docroot/lazysite/.install-state.json",
        'no state file written' );
    ok( !-f "$docroot/index.md",
        'no starter content installed' );
};

# --- 11. Manager CSS ships (manifest-tracked) to the web-served path ---

subtest 'manager CSS installs to the web-served manager/assets path' => sub {
    my ($docroot, $cgibin) = fresh_docroot();
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );

    my $css = "$docroot/manager/assets/manager.css";
    ok( -f $css, 'manager.css is at the web-served /manager/assets/ path' );

    # It is now shipped straight there by the manifest (code bucket), so an
    # upgrade always refreshes it. The old /lazysite/ copy is not installed and
    # any orphan from a prior install is cleaned up.
    my $state = load_state($docroot);
    ok( exists $state->{files}{$css}, 'manager.css is manifest-tracked in state' );
    ok( !-f "$docroot/lazysite/manager/assets/manager.css",
        'no stale copy left under the Apache-denied /lazysite/ tree' );
};

# --- 12. cgi-bin plugin endpoints link/install ---

subtest 'cgi-bin: form-handler and payment-demo reachable' => sub {
    my ($docroot, $cgibin) = fresh_docroot();
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );

    ok( -e "$cgibin/form-handler.pl",
        'form-handler.pl present in cgi-bin (symlink or copy)' );
    ok( -e "$cgibin/payment-demo.pl",
        'payment-demo.pl present in cgi-bin' );
};

# --- 13. --domain seeds lazysite.conf ---

subtest '--domain seeds lazysite.conf with site_name and site_url' => sub {
    my ($docroot, $cgibin) = fresh_docroot();
    run_install(
        '--docroot', $docroot, '--cgibin', $cgibin,
        '--domain', 'example.com',
    );
    my $conf = slurp("$docroot/lazysite/lazysite.conf");
    like( $conf, qr/site_name: example\.com/, 'site_name set from --domain' );
    like( $conf, qr/example\.com/, 'domain present in site_url' );
};

# --- 14. --theme warns but does not error ---

subtest '--theme prints warning and does not abort' => sub {
    my ($docroot, $cgibin) = fresh_docroot();
    my ($rc, $out) = run_install(
        '--docroot', $docroot, '--cgibin', $cgibin,
        '--theme', 'http://example.com/theme.tar.gz',
    );
    is( $rc, 0, 'exit 0 despite --theme' ) or diag $out;
    like( $out, qr/--theme is no longer supported/,
        'deprecation warning present' );
};

# --- 15. D013 runtime paths include layouts/ and lazysite-assets/ ---

subtest 'runtime_paths: D013 directories created' => sub {
    my ($docroot, $cgibin) = fresh_docroot();
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );

    ok( -d "$docroot/lazysite/layouts", 'layouts/ dir created' );
    ok( -d "$docroot/lazysite-assets",  'lazysite-assets/ dir created' );
    ok( -d "$docroot/lazysite/auth",    'auth/ dir created' );
    ok( -d "$docroot/lazysite/cache",   'cache/ dir created' );
};

# --- edited content stays preserved across REPEATED upgrades ---
# Regression: the preserve action used to record the on-disk (user) SHA as the
# baseline, so the next upgrade saw the file as "unedited" and clobbered it.
subtest 'edited content preserved across repeated upgrades' => sub {
    my ( $docroot, $cgibin ) = fresh_docroot();
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );

    my $index = "$docroot/index.md";
    open my $fh, '>', $index or die $!;
    print $fh "# my own homepage\n"; close $fh;
    my $mine = sha_file($index);

    my ( $rc1 ) = run_install( '--docroot', $docroot, '--cgibin', $cgibin );
    is( $rc1, 0, 'first upgrade ok' );
    is( sha_file($index), $mine, 'edited index.md preserved (1st upgrade)' );

    my ( $rc2 ) = run_install( '--docroot', $docroot, '--cgibin', $cgibin );
    is( $rc2, 0, 'second upgrade ok' );
    is( sha_file($index), $mine, 'edited index.md STILL preserved (2nd upgrade)' );
};

# --- an unwritable content file is non-fatal ---
subtest 'unwritable content file does not abort the install' => sub {
    my ( $docroot, $cgibin ) = fresh_docroot();
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );

    my $about = "$docroot/about.md";
    SKIP: {
        skip 'about.md not shipped', 2 unless -f $about;
        chmod 0444, $about;   # read-only: an unedited overwrite copy will fail
        my ( $rc, $out ) = run_install( '--docroot', $docroot, '--cgibin', $cgibin );
        is( $rc, 0, 'install completes despite an unwritable content file' );
        like( $out, qr/skipped \(not writable/, 'reports the skipped file' );
        chmod 0644, $about;
    }
};

subtest '--verify: detects a stale/altered code file (deploy-gap detector)' => sub {
    my ( $doc, $cgi ) = fresh_docroot();
    my ($irc) = run_install( '--docroot', $doc, '--cgibin', $cgi );
    is( $irc, 0, 'fresh install succeeds' );

    my ( $vrc, $vout ) =
        run_install( '--verify', '--docroot', $doc, '--cgibin', $cgi );
    is( $vrc, 0, 'verify passes on a clean install' ) or diag $vout;
    like( $vout, qr/VERIFY OK/, 'reports OK' );

    my $proc = "$cgi/lazysite-processor.pl";
    ok( -f $proc, 'processor installed to cgi-bin' );
    open my $a, '>>', $proc or die $!;
    print $a "\n# tampered\n";
    close $a;

    my ( $vrc2, $vout2 ) =
        run_install( '--verify', '--docroot', $doc, '--cgibin', $cgi );
    isnt( $vrc2, 0, 'verify FAILS when a code file no longer matches the manifest' );
    like( $vout2, qr/VERIFY FAILED/, 'reports the failure' );
    like( $vout2, qr/lazysite-processor\.pl/, 'names the offending file' );
};

subtest 'upgrade channel: a stable site refuses an edge build' => sub {
    my ( $doc, $cgi ) = fresh_docroot();
    my ($irc) = run_install( '--docroot', $doc, '--cgibin', $cgi );
    is( $irc, 0, 'fresh install ok' );

    make_path("$doc/lazysite/logs");
    open my $cf, '>>', "$doc/lazysite/lazysite.conf" or die $!;
    print $cf "update_channel: stable\n";
    close $cf;

    # Make the install-state look older so the next run is an UPGRADE, not a
    # reinstall. The repo manifest is an 'edge' build (build-manifest default).
    my $sp = "$doc/lazysite/.install-state.json";
    {
        open my $f, '<', $sp or die $!;
        local $/; my $j = <$f>; close $f;
        $j =~ s/"version"\s*:\s*"[^"]*"/"version":"0.0.1"/;
        open my $w, '>', $sp or die $!; print {$w} $j; close $w;
    }

    # --channel-check predicts the skip WITHOUT touching the site (so the deploy
    # can bail before any chown/perm changes).
    my ($cc) = run_install( '--channel-check', '--docroot', $doc );
    is( $cc, 3, '--channel-check exits 3 for a stable site + edge build' );

    my ( $rc2, $out2 ) = run_install( '--docroot', $doc, '--cgibin', $cgi );
    is( $rc2, 3, 'edge upgrade on a stable-channel site exits 3 (skipped)' );
    like( $out2, qr/SKIPPED/i, 'reports the skip' );
    my $audit = '';
    if ( open my $a, '<', "$doc/lazysite/logs/audit.log" ) {
        local $/; $audit = <$a>; close $a;
    }
    like( $audit, qr/upgrade-skipped/, 'skip recorded in the audit log' );

    # Control: an 'all' site (the default) is NOT gated - the upgrade proceeds.
    open my $cf2, '>', "$doc/lazysite/lazysite.conf" or die $!;
    print $cf2 "update_channel: all\n";
    close $cf2;
    {
        open my $f, '<', $sp or die $!;
        local $/; my $j = <$f>; close $f;
        $j =~ s/"version"\s*:\s*"[^"]*"/"version":"0.0.1"/;
        open my $w, '>', $sp or die $!; print {$w} $j; close $w;
    }
    my ($rc3) = run_install( '--docroot', $doc, '--cgibin', $cgi );
    is( $rc3, 0, 'an all-channel site upgrades normally (exit 0)' );
};

done_testing();

# --- helpers ---

sub slurp {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return '';
    my $t = do { local $/; <$fh> };
    close $fh;
    return $t // '';
}
