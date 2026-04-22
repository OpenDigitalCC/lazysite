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

die "install.pl not found at $INSTALL" unless -f $INSTALL;
die "release-manifest.json not found at $MANIFEST" unless -f $MANIFEST;

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

# --- 11. Derived manager CSS is not tracked in state ---

subtest 'manager CSS duplicate not in .install-state.json' => sub {
    my ($docroot, $cgibin) = fresh_docroot();
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );

    my $css_dup = "$docroot/manager/assets/manager.css";
    ok( -f $css_dup, 'manager CSS duplicate exists on disk' );

    my $state = load_state($docroot);
    ok( !exists $state->{files}{$css_dup},
        'duplicate is NOT tracked in state (derived path)' );
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

done_testing();

# --- helpers ---

sub slurp {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return '';
    my $t = do { local $/; <$fh> };
    close $fh;
    return $t // '';
}
