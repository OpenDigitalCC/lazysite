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
use File::Path     qw(make_path remove_tree);
use File::Temp     qw(tempdir);
use File::Basename qw(basename dirname);
use File::Copy     qw();
use Digest::SHA    qw(sha256_hex);
use JSON::PP       qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_manifest_guard);
use FlakeLog   qw(record_outcome);

# This file failed ONCE inside a combined lint+tools run and passed standalone
# and on the two runs after it (2026-08-14). One unreproducible failure is an
# anecdote that decays; recorded outcomes accumulate into a rate somebody can
# act on. Off unless LAZYSITE_FLAKE_LOG is set - see t/lib/FlakeLog.pm.
#
# Two things this END block must get right, both learned by getting them wrong:
# `local $?`, because the open/close inside it otherwise CLOBBERS the exit
# status and turns a passing file into a failing one; and asking Test::More's
# builder rather than reading $?, because END blocks run LIFO and Test::More's
# own END - the one that computes the status - is registered first and so runs
# LAST. At this point $? is not yet the verdict.
END {
    local $?;
    my $passing = eval { Test::More->builder->is_passing } ? 1 : 0;
    record_outcome(
        name   => 't/tools/03-install-pl.t',
        ok     => $passing,
        detail => ( $passing ? '' : 'assertions failed' ),
    );
}

my $ROOT    = "$FindBin::Bin/../..";
my $INSTALL = "$ROOT/install.pl";
# SM269 phase 1: the guard OWNS the shared repo-root manifest - it locks,
# builds if absent, and removes at scope end only if it built it. Six tests
# used to carry their own copy of that lifecycle, which is what kept racing.
my $MF_GUARD = repo_manifest_guard();

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

sub fresh_docroot {
    my $dir = tempdir( 'lazysite-install-test-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    make_path("$dir/site");
    make_path("$dir/cgi-bin");
    return ( "$dir/site", "$dir/cgi-bin", $dir );
}

sub run_install {
    my @args = @_;
    my $cmd  = join ' ', map { quotemeta } $^X, $INSTALL, @args;
    my $out  = `$cmd 2>&1`;
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
    my ( $docroot, $cgibin ) = fresh_docroot();
    my ( $rc,      $out )    = run_install(
        '--docroot', $docroot, '--cgibin', $cgibin,
    );
    is( $rc, 0, 'exit 0' ) or diag $out;

    ok( -f "$docroot/lazysite/.install-state.json", 'state file written' );
    my $state = load_state($docroot);
    is( $state->{schema_version}, '1',                  'schema_version' );
    is( $state->{version},        $manifest->{version}, 'version matches manifest' );
    ok( scalar keys %{ $state->{files} } > 50, 'state has many files' );

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
    my ( $rc,      $out )    = run_install( '--docroot', $docroot, '--cgibin', $cgibin );
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
    my ( $docroot, $cgibin ) = fresh_docroot();
    my ( $rc1, undef ) = run_install( '--docroot', $docroot, '--cgibin', $cgibin );
    is( $rc1, 0, 'fresh ok' );
    my $state1 = load_state($docroot);

    my ( $rc2, $out2 ) = run_install( '--docroot', $docroot, '--cgibin', $cgibin );
    is( $rc2, 0, 'reinstall exit 0' ) or diag $out2;

    like( $out2, qr/Installed:\s*0/,   'nothing new installed' );
    like( $out2, qr/Overwrote:\s*\d+/, 'files overwrote' );
    like( $out2, qr/Preserved:\s*0/,   'nothing preserved' );
    like( $out2, qr/Removed:\s*0/,     'nothing removed' );
    like( $out2, qr/Backup:/,          'backup path shown' );

    my $state2 = load_state($docroot);
    is_deeply( [ sort keys %{ $state2->{files} } ],
        [ sort keys %{ $state1->{files} } ],
        'file set unchanged' );
};

# --- 3. Seed edited: preserve; code edited: overwrite ---

subtest 'seed edited preserved; code edited overwritten' => sub {
    my ( $docroot, $cgibin ) = fresh_docroot();
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

    my ( $rc, $out ) = run_install( '--docroot', $docroot, '--cgibin', $cgibin );
    is( $rc, 0, 'reinstall exit 0' ) or diag $out;

    like( $out, qr/Preserved:\s*1/,   'one preserved' );
    like( $out, qr/Overwrote:/,       'overwrote count' );
    like( $out, qr{- \Q$seed_path\E}, 'seed path listed as preserved' );

    is( sha_file($seed_path), $seed_after_edit_sha,
        'seed file disk content unchanged' );
    unlike( slurp($code_path), qr/# operator edit/,
        'code file overwritten (operator edit gone)' );
};

# --- 4. File removed from manifest (simulate by editing state) ---

subtest 'upgrade: unedited orphan removed; edited orphan preserved' => sub {
    my ( $docroot, $cgibin ) = fresh_docroot();
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );

    # Create two fake "previously installed" files and add them to state
    # so the next run sees them as "in stored but not in new manifest".
    my $state           = load_state($docroot);
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

    my ( $rc, $out ) = run_install( '--docroot', $docroot, '--cgibin', $cgibin );
    is( $rc, 0, 'exit 0' ) or diag $out;

    ok( !-f $unedited_orphan, 'unedited orphan removed' );
    ok( -f $edited_orphan,    'edited orphan preserved' );
    like( $out, qr/orphan/i, 'orphan warning in output' );
};

# --- 5. Backup created on upgrade ---

subtest 'backup created, extracts, contains state file' => sub {
    my ( $docroot, $cgibin ) = fresh_docroot();
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );

    my @backups = glob("$docroot/lazysite/backups/lazysite-backup-*.tar.gz");
    is( scalar @backups, 1, 'one backup produced' );
    ok( -s $backups[0], 'backup non-empty' );

    my $peek = `tar tzf $backups[0] 2>&1`;
    like( $peek, qr/\.install-state\.json/, 'backup contains state file' );
    like( $peek, qr/index\.md/,             'backup contains a starter file' );

    # SM268 03-F10: the installer's own backups never got a .sha256 sidecar.
    # SM183 said "every site package and backup now gets one" and the
    # installer's did not - it cannot load Lazysite::Manager::Backups, so the
    # writer simply was not there. That also made apply_retention's
    # `unlink "$backup.sha256"` dead code: it retired a file nothing wrote.
    my $side = "$backups[0].sha256";
    ok( -f $side, 'the backup carries an integrity sidecar' );
    if ( -f $side ) {
        open my $sfh, '<', $side or die $!;
        my $line = <$sfh>;
        close $sfh;
        my ( $sha, $named ) = ( $line // '' ) =~ /\A([0-9a-f]{64})\s+(\S+)/;
        ok( defined $sha, 'in sha256sum -c format' );
        is( $named, ( $backups[0] =~ s{.*/}{}r ),
            'naming the artefact it describes - the second field is what stops '
                . 'a sidecar being read as some other file\'s' );
        my $got = `sha256sum \Q$backups[0]\E 2>/dev/null`;
        ($got) = ( $got // '' ) =~ /\A([0-9a-f]{64})/;
        is( $got, $sha, 'and the digest matches the bytes on disk' ) if defined $got;
    }
};

# --- 6. Retention: 4 runs with retention=3 -> oldest removed ---

subtest 'backup_retention: 3 keeps 3 most recent' => sub {
    my ( $docroot, $cgibin ) = fresh_docroot();
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
    my ( $docroot, $cgibin ) = fresh_docroot();
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
    my ( $docroot, $cgibin ) = fresh_docroot();
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );

    # Snapshot starting content of a seed file
    my $seed     = "$docroot/contact.md";
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
    my ( $rc, $out ) = run_install( '--docroot', $docroot, '--restore' );
    is( $rc, 0, 'restore exit 0' ) or diag $out;

    is( slurp($seed), $operator_content, 'seed restored to operator-edited content' );
    like( $out, qr/Restore complete/, 'restore complete message' );
};

# --- 8. Restore specific backup ---

subtest 'restore --backup PATH: named tarball restored' => sub {
    my ( $docroot, $cgibin ) = fresh_docroot();
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );

    # Edit a seed, reinstall to back up the edited state
    my $seed = "$docroot/contact.md";
    open my $e, '>', $seed or die $!;
    print $e "# mark A\n";
    close $e;
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );

    my @backups      = glob("$docroot/lazysite/backups/lazysite-backup-*.tar.gz");
    my $first_backup = $backups[0];

    # Change again, reinstall for a second backup
    open my $e2, '>', $seed or die $!;
    print $e2 "# mark B\n";
    close $e2;
    sleep 1;
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );

    # Restore the first (older) backup explicitly
    my ( $rc, $out ) = run_install(
        '--docroot', $docroot, '--restore', '--backup', $first_backup,
    );
    is( $rc, 0, 'restore exit 0' ) or diag $out;

    like( slurp($seed), qr/mark A/, 'seed restored to first-backup content' );
    unlike( slurp($seed), qr/mark B/, 'second-backup content not present' );
};

# --- 9. --list-backups ---

subtest '--list-backups shows expected output' => sub {
    my ( $docroot, $cgibin ) = fresh_docroot();
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );

    my ( $rc, $out ) = run_install( '--docroot', $docroot, '--list-backups' );
    is( $rc, 0, 'list-backups exit 0' ) or diag $out;
    like( $out, qr/lazysite-backup-/, 'backup file name shown' );
    like( $out, qr/Size/,             'header row' );
};

# --- 10. --dry-run makes no changes ---

subtest '--dry-run does not modify filesystem' => sub {
    my ( $docroot, $cgibin ) = fresh_docroot();

    my ( $rc, $out ) = run_install(
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
    my ( $docroot, $cgibin ) = fresh_docroot();
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
    my ( $docroot, $cgibin ) = fresh_docroot();
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );

    ok( -e "$cgibin/form-handler.pl",
        'form-handler.pl present in cgi-bin (symlink or copy)' );
    ok( -e "$cgibin/payment-demo.pl",
        'payment-demo.pl present in cgi-bin' );
};

# --- 13. --domain seeds lazysite.conf ---

subtest '--domain seeds lazysite.conf with site_name and site_url' => sub {
    my ( $docroot, $cgibin ) = fresh_docroot();
    run_install(
        '--docroot', $docroot, '--cgibin', $cgibin,
        '--domain',  'example.com',
    );
    my $conf = slurp("$docroot/lazysite/lazysite.conf");
    like( $conf, qr/site_name: example\.com/, 'site_name set from --domain' );
    like( $conf, qr/example\.com/,            'domain present in site_url' );
};

# --- 14. --theme warns but does not error ---

subtest '--theme prints warning and does not abort' => sub {
    my ( $docroot, $cgibin ) = fresh_docroot();
    my ( $rc,      $out )    = run_install(
        '--docroot', $docroot, '--cgibin', $cgibin,
        '--theme',   'http://example.com/theme.tar.gz',
    );
    is( $rc, 0, 'exit 0 despite --theme' ) or diag $out;
    like( $out, qr/--theme is no longer supported/,
        'deprecation warning present' );
};

# --- 15. D013 runtime paths include layouts/ and lazysite-assets/ ---

subtest 'runtime_paths: D013 directories created' => sub {
    my ( $docroot, $cgibin ) = fresh_docroot();
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

    my ($rc1) = run_install( '--docroot', $docroot, '--cgibin', $cgibin );
    is( $rc1,             0,     'first upgrade ok' );
    is( sha_file($index), $mine, 'edited index.md preserved (1st upgrade)' );

    my ($rc2) = run_install( '--docroot', $docroot, '--cgibin', $cgibin );
    is( $rc2,             0,     'second upgrade ok' );
    is( sha_file($index), $mine, 'edited index.md STILL preserved (2nd upgrade)' );
};

# --- an unwritable content file is non-fatal ---
subtest 'unwritable content file does not abort the install' => sub {
    my ( $docroot, $cgibin ) = fresh_docroot();
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );

    my $about = "$docroot/about.md";
SKIP: {
        skip 'about.md not shipped', 2 unless -f $about;
        chmod 0444, $about;    # read-only: an unedited overwrite copy will fail
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
    like( $vout2, qr/VERIFY FAILED/,          'reports the failure' );
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

    # --force overrides the channel policy: the edge upgrade proceeds.
    my ( $rc3, $out3 ) = run_install( '--docroot', $doc, '--cgibin', $cgi, '--force' );
    is( $rc3, 0, '--force upgrades a stable-channel site with an edge build' );
    like( $out3, qr/--force|override/i, '--force reports the override' );
    my $audit2 = '';
    if ( open my $a2, '<', "$doc/lazysite/logs/audit.log" ) { local $/; $audit2 = <$a2>; close $a2; }
    like( $audit2, qr/upgrade-forced/, 'forced override recorded in the audit log' );

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

subtest 'channel ladder: beta sits between edge and stable' => sub {
    my ( $doc, $cgi ) = fresh_docroot();
    my ($irc) = run_install( '--docroot', $doc, '--cgibin', $cgi );
    is( $irc, 0, 'fresh install ok' );
    make_path("$doc/lazysite/logs");

    my $sp        = "$doc/lazysite/.install-state.json";
    my $age_state = sub {
        open my $f, '<', $sp or die $!;
        local $/; my $j = <$f>; close $f;
        $j =~ s/"version"\s*:\s*"[^"]*"/"version":"0.0.1"/;
        open my $w, '>', $sp or die $!; print {$w} $j; close $w;
    };
    my $set_payload_channel = sub {
        my ($ch) = @_;
        open my $f, '<', $MANIFEST or die $!;
        local $/; my $j = <$f>; close $f;
        $j =~ s/"channel"\s*:\s*"[^"]*"/"channel" : "$ch"/;
        open my $w, '>', $MANIFEST or die $!; print {$w} $j; close $w;
    };
    my $set_site_channel = sub {
        my ($ch) = @_;
        my ($rc) = run_install( '--channel', $ch, '--docroot', $doc );
        is( $rc, 0, "site moved to the '$ch' channel" );
    };

    # A beta site refuses an edge build (the repo manifest default)...
    $set_site_channel->('beta');
    $age_state->();
    my ($cc) = run_install( '--channel-check', '--docroot', $doc );
    is( $cc, 3, '--channel-check: beta site refuses an edge build' );
    my ( $rc2, $out2 ) = run_install( '--docroot', $doc, '--cgibin', $cgi );
    is( $rc2, 3, 'edge upgrade on a beta site exits 3 (skipped)' );
    like( $out2, qr/'beta' update channel/, 'the skip names the site channel' );

    # ...but accepts a beta build...
    $set_payload_channel->('beta');
    my ($rc3) = run_install( '--docroot', $doc, '--cgibin', $cgi );
    is( $rc3, 0, 'beta upgrade on a beta site proceeds' );

    # ...while a stable site refuses that same beta build...
    $set_site_channel->('stable');
    $age_state->();
    my ($rc4) = run_install( '--docroot', $doc, '--cgibin', $cgi );
    is( $rc4, 3, 'beta upgrade on a stable site exits 3 (skipped)' );

    # ...and a beta site accepts a stable build (up-ladder is always fine).
    $set_payload_channel->('stable');
    $set_site_channel->('beta');
    my ($rc5) = run_install( '--docroot', $doc, '--cgibin', $cgi );
    is( $rc5, 0, 'stable upgrade on a beta site proceeds' );

    $set_payload_channel->('edge');    # restore the shared manifest
};

subtest '--channel sets the site update channel in lazysite.conf' => sub {
    my ( $doc, $cgi ) = fresh_docroot();
    my ($irc) = run_install( '--docroot', $doc, '--cgibin', $cgi );
    is( $irc, 0, 'fresh install ok' );
    make_path("$doc/lazysite/logs");

    my ($rc) = run_install( '--channel', 'stable', '--docroot', $doc );
    is( $rc, 0, '--channel stable exits 0' );
    like( slurp("$doc/lazysite/lazysite.conf"), qr/^update_channel:\s*stable\s*$/m,
        'update_channel: stable written' );

    # Move back to edge - replaces the line, does not duplicate it.
    my ($rc2) = run_install( '--channel', 'edge', '--docroot', $doc );
    is( $rc2, 0, '--channel edge exits 0' );
    my $conf = slurp("$doc/lazysite/lazysite.conf");
    like( $conf, qr/^update_channel:\s*edge\s*$/m, 'update_channel: edge written' );
    my @hits = ( $conf =~ /^update_channel:/mg );
    is( scalar @hits, 1, 'the key is replaced, not duplicated' );

    my ($rc3) = run_install( '--channel', 'bogus', '--docroot', $doc );
    is( $rc3, 2, 'a bad --channel value exits 2 (no change)' );

    like( slurp("$doc/lazysite/logs/audit.log"), qr/channel-set/,
        'the channel change is recorded in the audit log' );

    # Regression: the temp+rename replace must PRESERVE the conf's mode. It
    # used to leave the temp file's umask-born mode, so a site-user channel
    # sweep silently turned a group-writable 0664 conf into 0644 and the
    # manager (web-server user, no-suexec) could no longer save settings.
    # (Group preservation is best-effort chown and needs root to assert;
    # mode is deterministic, so that is what is pinned here.)
    my $confp = "$doc/lazysite/lazysite.conf";
    chmod 0664, $confp or die "chmod: $!";
    my ($rc4) = run_install( '--channel', 'beta', '--docroot', $doc );
    is( $rc4, 0, '--channel beta exits 0' );
    is( ( stat $confp )[2] & 07777, 0664,
        'the conf keeps its 0664 mode across the channel write' );
};

subtest '--restore-full migrates a full backup to a new domain' => sub {
    my $write = sub { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh };

    my $src = tempdir( 'lazysite-full-src-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    make_path("$src/lazysite/auth");
    make_path("$src/lazysite/logs");
    $write->( "$src/lazysite/lazysite.conf", "site_name: X\ndomain: temp.example.com\n" );
    $write->( "$src/lazysite/auth/.secret",  "hmac-secret\n" );
    $write->( "$src/index.md",               "# Home\n" );
    my $arch = tempdir( 'lazysite-full-arch-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    my $tb   = "$arch/full.tar.gz";    # outside $src so tar does not read its own output
    system( 'tar', 'czf', $tb, '-C', $src, '.' ) == 0 or die "tar failed";

    my $dst = tempdir( 'lazysite-full-dst-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    my ( $rc, $out ) = run_install(
        '--restore-full', $tb, '--docroot', $dst, '--domain', 'www.final.com' );
    is( $rc, 0, '--restore-full exits 0' );
    like( slurp("$dst/lazysite/lazysite.conf"), qr/^domain:\s*www\.final\.com\s*$/m,
        'site domain rewritten to the target (migration)' );
    ok( -f "$dst/lazysite/auth/.secret", 'auth secret restored (full migration carries accounts)' );
    ok( -f "$dst/index.md",              'content restored' );
    like( slurp("$dst/lazysite/logs/audit.log"), qr/full-restore/,
        'the full restore is recorded in the audit log' )
        if -f "$dst/lazysite/logs/audit.log";
};

# --- homepage-replacement incident regression ---
# A seed file that EXISTS on disk but is NOT tracked in the install state (e.g.
# authored via the manager / WebDAV, seeded by a different install path, or written
# before it became manifest-tracked) must be PRESERVED on upgrade - never clobbered
# with the shipped boilerplate. Before the fix, an untracked dest was planned as a
# fresh 'install' and overwrote the operator's homepage.
subtest 'untracked pre-existing seed file preserved (not clobbered) on upgrade' => sub {
    my ( $docroot, $cgibin ) = fresh_docroot();
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );

    my $index = "$docroot/index.md";
    open my $fh, '>', $index or die $!;
    print $fh "# the operator homepage\n"; close $fh;
    my $mine = sha_file($index);

    # Drop index.md from the tracked state so the upgrade sees it as untracked,
    # while it is still present on disk (the incident condition).
    my $state = load_state($docroot);
    delete $state->{files}{$index};
    open my $sfh, '>:raw', "$docroot/lazysite/.install-state.json" or die $!;
    print $sfh JSON::PP->new->canonical(1)->pretty(1)->encode($state);
    close $sfh;

    my ( $rc, $out ) = run_install( '--docroot', $docroot, '--cgibin', $cgibin );
    is( $rc, 0, 'upgrade exit 0' ) or diag $out;
    is( sha_file($index), $mine,
        'untracked-but-present homepage preserved (not overwritten with boilerplate)' );
    like( slurp($index), qr/the operator homepage/, 'homepage content is the operator content' );

    my $state2 = load_state($docroot);
    ok( exists $state2->{files}{$index}, 'homepage adopted into state for future upgrades' );

    # And it stays preserved on the next upgrade too.
    run_install( '--docroot', $docroot, '--cgibin', $cgibin );
    is( sha_file($index), $mine, 'homepage STILL preserved on a subsequent upgrade' );
};

# --- audit-completeness round: fresh install leaves a working, shared trail ---
# The 0.7.5 field defect: install created audit.log 0644 (umask default), the
# www-data CGI could never append, and every subsequent event vanished
# silently. Pin: mode 0664 with the group-write bit (the "second identity can
# append" contract, asserted via mode+group bits since tests are not root),
# the install event present WITH the seeded-channel detail, and setup-manager
# appending its TWO events with cli origin + real attribution.
subtest 'fresh install: audit.log 0664, install event + channel, setup-manager events' => sub {
    my ( $docroot, $cgibin ) = fresh_docroot();
    my $old = umask 0022;    # the field umask that produced 0644
    my ( $rc, $out ) = run_install(
        '--docroot', $docroot, '--cgibin', $cgibin, '--domain', 'audit.test' );
    umask $old;
    is( $rc, 0, 'fresh install ok' ) or diag $out;

    my $log = "$docroot/lazysite/logs/audit.log";
    ok( -f $log, 'audit.log created by the install event' );
    my $mode = ( stat $log )[2] & 07777;
    is( $mode, 0664, sprintf( 'audit.log is 0664 (got %04o) despite umask 0022', $mode ) );
    ok( $mode & 0020, 'group-write bit set: the CGI identity (via the setgid ' .
            'logs dir group) can append' );

    my $audit = slurp($log);
    like( $audit, qr/\| system \| installed \| .* \| ok \| install \| update_channel: stable/,
        'install event present, carrying the seeded channel as detail' );

    # setup-manager through the users tool (the provisioning path runs exactly
    # this): exactly two more events, origin cli, attributed to the real user.
    my @before = split /\n/, $audit;
    my $users  = "$FindBin::Bin/../../tools/lazysite-users.pl";
    my $sout   = qx{$^X "$users" --docroot "$docroot" setup-manager pw-test-1 2>&1};
    my @after  = split /\n/, slurp($log);
    is( scalar @after, scalar(@before) + 2,
        'setup-manager appended exactly TWO events' ) or diag $sout;
    my $me = getpwuid($<) // "uid:$<";
    like( $after[-2], qr/\| \Q$me\E \| setup-manager \| lazysite-admins \| .* \| ok \| cli/,
        'setup-manager event: cli origin, invoking-user attribution, group target' );
    like( $after[-1], qr/\| \Q$me\E \| user-passwd \| manager \| .* \| ok \| cli/,
        'credential-issue event for the manager account' );
    unlike( slurp($log), qr/pw-test-1/, 'the password itself is not in the trail' );

    # Split-identity invariant: any secret minted so far is exactly 0660
    # (owner+group, never world) - a CLI-context mint must not lock the
    # www-data CGI out (field 500: 0600 site-user .secret).
    for my $rel ( qw(
        lazysite/auth/.secret lazysite/forms/.secret
        lazysite/manager/.csrf-secret lazysite/logs/.access-salt
        ) ) {
        next unless -f "$docroot/$rel";
        my $sm = ( stat "$docroot/$rel" )[2] & 07777;
        is( $sm, 0660, "$rel minted 0660" );
    }
};

# --- structural: every CGI-writable file from lazysite-check's 4b list is g+w ---
# Driven off the SAME qw() list the check tool uses, parsed from its source,
# so a future addition to the list is automatically covered here.
subtest 'fresh install: every 4b CGI-writable file is group-writable' => sub {
    my $check_src = slurp("$FindBin::Bin/../../tools/lazysite-check.pl");
    my ($list) = $check_src =~
        /config\/auth files the CGI overwrites in place.*?qw\(\s*(.*?)\)/s;
    ok( defined $list, '4b list parsed from tools/lazysite-check.pl' ) or return;
    my @rels = split ' ', $list;
    ok( scalar @rels >= 6, 'the 4b list has the expected breadth' )
        or diag "parsed: @rels";

    my ( $docroot, $cgibin ) = fresh_docroot();
    my $old = umask 0022;
    my ($rc) = run_install(
        '--docroot', $docroot, '--cgibin', $cgibin, '--domain', 'perm.test' );
    umask $old;
    is( $rc, 0, 'fresh install ok' );

    for my $rel (@rels) {
        my $p = "$docroot/$rel";
    SKIP: {
            skip "$rel not created by a fresh install", 1 unless -f $p;
            my $mode = ( stat $p )[2] & 07777;
            ok( $mode & 0020,
                sprintf( '%s is group-writable (%04o) - the CGI can write it in place',
                    $rel, $mode ) );
        }
    }
};

# --- SM413: an upgrade invalidates rendered HTML -----------------------------
#
# The field: a homepage served a render produced under 0.10.13 through FOUR
# subsequent deployments, corrected only when an operator invalidated by hand.
# A cached page regenerates when its SOURCE changes; an upgrade changes no
# source, so a page nobody edits keeps its pre-upgrade render for ever -
# including any head-contract or security header the new build introduced.
#
# The installer already knew the rule: the ROLLBACK path dropped rendered HTML
# for exactly this reason, and the upgrade path did not. This asserts both
# directions now, and asserts the boundary as hard as the behaviour - a
# too-eager clear that took the whole cache tree, or ran on a fresh install,
# would be a different defect wearing this fix's clothes.
subtest 'an upgrade drops rendered HTML, and only that' => sub {
    my ( $docroot, $cgibin ) = fresh_docroot();
    my ( $rc1,     $out1 )   = run_install( '--docroot', $docroot, '--cgibin', $cgibin );
    is( $rc1, 0, 'fresh install ok' ) or diag $out1;

    unlike( $out1, qr/Invalidated \d+ rendered page/,
        'a FRESH install reports no invalidation - there is nothing rendered '
            . 'yet, and a number that means nothing is worse than silence' );

    # Stand in for a rendered site: pages in the cache, plus a NON-render
    # neighbour that must survive.
    my $cache = "$docroot/lazysite/cache";
    make_path("$cache/hosts/example.test");
    for my $f ( "$cache/index.html", "$cache/about.html",
        "$cache/hosts/example.test/index.html" )
    {
        open my $fh, '>', $f or die $!;
        print {$fh} "<html>rendered under the OLD build</html>";
        close $fh;
    }
    open my $keep, '>', "$cache/stats-export.json" or die $!;
    print {$keep} '{"v":2}';
    close $keep;

    # A REAL upgrade, not a reinstall: same-version reruns are mode 'reinstall'
    # and deliberately do NOT invalidate - the renders already came from this
    # code, so dropping them would be churn without a reason. Backdating the
    # recorded version is what makes the next run an upgrade, which is the
    # case SM413 is about. (The first version of this subtest installed twice
    # and never reached the path it was testing.)
    # And the site must ACCEPT the build: update_channel defaults to 'stable'
    # while a locally-built manifest is 'edge', so an unforced upgrade is
    # correctly SKIPPED (rc 3) - the ladder failing closed, exactly as
    # designed. Put the fixture site on edge rather than reaching for --force,
    # which would test the override branch instead of the ordinary one.
    my $conf = "$docroot/lazysite/lazysite.conf";
    if ( -f $conf ) {
        open my $rh, '<', $conf or die $!;
        my $c = do { local $/; <$rh> };
        close $rh;
        # REPLACE, not append: the installer seeds an update_channel line and
        # the reader takes the first match, so an appended one is inert - the
        # first attempt here appended and the upgrade went on being skipped.
        $c =~ s/^update_channel:.*$/update_channel: edge/m
            or $c .= "update_channel: edge\n";
        open my $wh, '>', $conf or die $!;
        print {$wh} $c;
        close $wh;
    }

    my $sp = "$docroot/lazysite/.install-state.json";
    if ( -f $sp ) {
        open my $rh, '<', $sp or die $!;
        my $j = do { local $/; <$rh> };
        close $rh;
        $j =~ s/"version"\s*:\s*"[^"]+"/"version":"0.0.1"/;
        open my $wh, '>', $sp or die $!;
        print {$wh} $j;
        close $wh;
    }

    my ( $rc2, $out2 ) = run_install( '--docroot', $docroot, '--cgibin', $cgibin );
    is( $rc2, 0, 'upgrade ok' ) or diag $out2;

    like( $out2, qr/Invalidated 3 rendered page/,
        'the upgrade invalidates every rendered page, including per-host copies' )
        or diag($out2);
    ok( !-e "$cache/index.html", 'the homepage render is gone - the field case' );
    ok( !-e "$cache/hosts/example.test/index.html",
        'and the per-host copy with it, which is what a multi-domain site serves' );
    ok( -e "$cache/stats-export.json",
        'but non-render cache state SURVIVES - this is a re-render trigger, '
            . 'not a cache reset' );
    ok( -d "$cache", 'and the cache directory itself is still there' );

    # Honest note: a sabotage that made this fire on a FRESH install too is not
    # caught here and is not exploitable - a fresh install has no cache
    # directory, so the helper finds nothing and stays silent. The mode guard
    # earns its place for the odd real state (a docroot with renders but no
    # install state) rather than for anything this fixture can construct.
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
