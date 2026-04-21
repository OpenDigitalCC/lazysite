#!/usr/bin/perl
# D021a: tests for tools/build-manifest.pl. Builds small fixture
# trees via File::Temp and drives the script as a subprocess.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Digest::SHA qw(sha256_hex);
use JSON::PP qw(decode_json encode_json);
use FindBin;

my $root   = "$FindBin::Bin/../..";
my $script = "$root/tools/build-manifest.pl";

die "build-manifest.pl not found at $script" unless -f $script;

sub write_file {
    my ( $path, $content ) = @_;
    make_path( dirname($path) ) unless -d dirname($path);
    open my $fh, '>', $path or die "open $path: $!";
    print $fh $content;
    close $fh;
}

sub write_json {
    my ( $path, $data ) = @_;
    write_file( $path, encode_json($data) );
}

sub write_default_config {
    my ($path) = @_;
    write_json(
        $path,
        {
            schema_version => "1",
            rules          => [
                { pattern => "^bin/(.+)\\.pl\$",
                  install_to => "{CGIBIN}/\$1.pl", bucket => "code" },
                { pattern => "^starter/(.+)\$",
                  install_to => "{DOCROOT}/\$1", bucket => "seed" },
            ],
            exclude => [ "^tests/", "^README\\.md\$" ],
            overrides      => [],
            runtime_paths  => [
                { path => "{DOCROOT}/lazysite/auth",
                  mode => "0750", purpose => "creds" },
            ],
        }
    );
}

sub run_script {
    my (@args) = @_;
    my $cmd = join(' ', map { quotemeta } $^X, $script, @args) . " 2>&1";
    my $out = qx($cmd);
    return ( $? >> 8, $out );
}

# --- 1. Happy path ---

subtest 'happy path: manifest shape and fields' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/bin/foo.pl",       "script\n" );
    write_file( "$dir/starter/index.md", "home\n" );
    write_file( "$dir/tests/unused.t",   "skipped\n" );
    write_file( "$dir/README.md",        "readme\n" );
    write_default_config( "$dir-cfg/classification.json" );

    my ( $rc, $out ) = run_script(
        '--staged',  $dir,
        '--config',  "$dir-cfg/classification.json",
        '--version', '1.2.3',
        '--out',     "$dir/release-manifest.json",
    );
    is( $rc, 0, 'exit 0 on success' ) or diag $out;

    open my $fh, '<', "$dir/release-manifest.json" or die $!;
    my $m = decode_json( do { local $/; <$fh> } );
    close $fh;

    is( $m->{schema_version}, '1',     'schema_version' );
    is( $m->{version},        '1.2.3', 'version' );
    is( scalar @{ $m->{files} }, 2,    'two files (tests/ excluded, README excluded)' );
    like( $m->{generated}, qr/^\d{4}-\d{2}-\d{2}T/, 'generated looks like ISO timestamp' );
    ok( ref $m->{runtime_paths} eq 'ARRAY', 'runtime_paths present' );
    is( scalar @{ $m->{runtime_paths} }, 1, 'one runtime_path' );
};

# --- 2. Sorted by install_to ---

subtest 'files sorted by install_to' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    for my $n (qw(zebra alpha mango)) {
        write_file( "$dir/starter/$n.md", "x\n" );
    }
    write_default_config( "$dir-cfg/classification.json" );

    run_script(
        '--staged', $dir,
        '--config', "$dir-cfg/classification.json",
        '--out',    "$dir/release-manifest.json",
    );
    open my $fh, '<', "$dir/release-manifest.json" or die $!;
    my $m = decode_json( do { local $/; <$fh> } );
    close $fh;
    my @paths = map { $_->{install_to} } @{ $m->{files} };
    is_deeply( \@paths,
        [
            '{DOCROOT}/alpha.md',
            '{DOCROOT}/mango.md',
            '{DOCROOT}/zebra.md',
        ],
        'install_to sort is alphabetical' );
};

# --- 3. SHA-256 correct ---

subtest 'sha256 matches known value' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my $body = "hello world\n";
    write_file( "$dir/starter/greet.md", $body );
    write_default_config( "$dir-cfg/classification.json" );
    run_script(
        '--staged', $dir,
        '--config', "$dir-cfg/classification.json",
        '--out',    "$dir/release-manifest.json",
    );
    open my $fh, '<', "$dir/release-manifest.json" or die $!;
    my $m = decode_json( do { local $/; <$fh> } );
    close $fh;
    my $expected = sha256_hex($body);
    is( $m->{files}[0]{sha256}, $expected, 'sha256 matches expected digest' );
    is( $m->{files}[0]{size},   length($body), 'size is byte count' );
};

# --- 4. --check passes on fresh manifest ---

subtest '--check passes on freshly-generated manifest' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/starter/a.md", "one\n" );
    write_default_config( "$dir-cfg/classification.json" );
    run_script(
        '--staged', $dir,
        '--config', "$dir-cfg/classification.json",
        '--out',    "$dir/release-manifest.json",
    );
    my ( $rc, $out ) = run_script(
        '--staged', $dir,
        '--config', "$dir-cfg/classification.json",
        '--out',    "$dir/release-manifest.json",
        '--check',
    );
    is( $rc, 0, '--check exit 0' ) or diag $out;
    like( $out, qr/OK|ok/, 'output mentions OK' );
};

# --- 5. --check fails on modified file ---

subtest '--check fails on modified file' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/starter/a.md", "original\n" );
    write_default_config( "$dir-cfg/classification.json" );
    run_script(
        '--staged', $dir,
        '--config', "$dir-cfg/classification.json",
        '--out',    "$dir/release-manifest.json",
    );
    # Modify the file after manifest was generated
    write_file( "$dir/starter/a.md", "TAMPERED\n" );
    my ( $rc, $out ) = run_script(
        '--staged', $dir,
        '--config', "$dir-cfg/classification.json",
        '--out',    "$dir/release-manifest.json",
        '--check',
    );
    isnt( $rc, 0, '--check exit non-zero on tampered file' );
    like( $out, qr/starter\/a\.md/, 'tampered path appears in stderr' );
};

# --- 6. --check detects file not in manifest ---

subtest '--check flags new file that matches a rule' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/starter/a.md", "one\n" );
    write_default_config( "$dir-cfg/classification.json" );
    run_script(
        '--staged', $dir,
        '--config', "$dir-cfg/classification.json",
        '--out',    "$dir/release-manifest.json",
    );
    # Add a new file after manifest was generated
    write_file( "$dir/starter/b.md", "new\n" );
    my ( $rc, $out ) = run_script(
        '--staged', $dir,
        '--config', "$dir-cfg/classification.json",
        '--out',    "$dir/release-manifest.json",
        '--check',
    );
    isnt( $rc, 0, '--check exit non-zero when new file present' );
    like( $out, qr/b\.md/, 'new path appears in stderr' );
};

# --- 7. Exclude pattern skips file ---

subtest 'exclude pattern skips a matching file' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/starter/keep.md",       "keep\n" );
    write_file( "$dir/tests/skipme.t",        "ignore\n" );
    write_default_config( "$dir-cfg/classification.json" );
    run_script(
        '--staged', $dir,
        '--config', "$dir-cfg/classification.json",
        '--out',    "$dir/release-manifest.json",
    );
    open my $fh, '<', "$dir/release-manifest.json" or die $!;
    my $m = decode_json( do { local $/; <$fh> } );
    close $fh;
    my @paths = map { $_->{path} } @{ $m->{files} };
    is_deeply( \@paths, [ 'starter/keep.md' ], 'only non-excluded file present' );
};

# --- 8. Override replaces rule-based bucket ---

subtest 'override replaces rule-based classification' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/starter/special.md", "special\n" );
    write_json(
        "$dir-cfg/classification.json",
        {
            schema_version => "1",
            rules          => [
                { pattern => "^starter/(.+)\$",
                  install_to => "{DOCROOT}/\$1", bucket => "seed" },
            ],
            exclude   => [],
            overrides => [
                { path => "starter/special.md",
                  install_to => "{DOCROOT}/special.md", bucket => "code" },
            ],
            runtime_paths => [],
        }
    );
    run_script(
        '--staged', $dir,
        '--config', "$dir-cfg/classification.json",
        '--out',    "$dir/release-manifest.json",
    );
    open my $fh, '<', "$dir/release-manifest.json" or die $!;
    my $m = decode_json( do { local $/; <$fh> } );
    close $fh;
    is( $m->{files}[0]{bucket}, 'code', 'override bucket applied' );
};

# --- 9. Unmatched file causes failure ---

subtest 'unmatched file fails with useful error' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/orphan.txt", "no rule matches me\n" );
    write_default_config( "$dir-cfg/classification.json" );
    my ( $rc, $out ) = run_script(
        '--staged', $dir,
        '--config', "$dir-cfg/classification.json",
        '--out',    "$dir/release-manifest.json",
    );
    isnt( $rc, 0, 'exit non-zero on unmatched file' );
    like( $out, qr/orphan\.txt/, 'unmatched path named in error' );
};

# --- 10. Duplicate install_to causes failure ---

subtest 'duplicate install_to fails' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    write_file( "$dir/bin/dup1.pl", "a\n" );
    write_file( "$dir/bin/dup2.pl", "b\n" );
    write_json(
        "$dir-cfg/classification.json",
        {
            schema_version => "1",
            rules          => [
                { pattern => "^bin/.+\\.pl\$",
                  install_to => "{CGIBIN}/same.pl", bucket => "code" },
            ],
            exclude => [], overrides => [], runtime_paths => [],
        }
    );
    my ( $rc, $out ) = run_script(
        '--staged', $dir,
        '--config', "$dir-cfg/classification.json",
        '--out',    "$dir/release-manifest.json",
    );
    isnt( $rc, 0, 'exit non-zero on duplicate install_to' );
    like( $out, qr/[Dd]uplicate/, 'error mentions duplicate' );
};

done_testing();
