#!/usr/bin/perl
# D021b: tests for tools/manifest-to-sbom.pl.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use JSON::PP qw(decode_json encode_json);
use Digest::SHA qw(sha256_hex);
use FindBin;

my $root   = "$FindBin::Bin/../..";
my $script = "$root/tools/manifest-to-sbom.pl";
die "manifest-to-sbom.pl not found at $script" unless -f $script;

sub write_file {
    my ( $path, $content ) = @_;
    make_path( dirname($path) ) unless -d dirname($path);
    open my $fh, '>', $path or die "open $path: $!";
    print $fh $content;
    close $fh;
}
sub write_json { write_file( $_[0], encode_json( $_[1] ) ); }

sub run_script {
    my @args = @_;
    my $cmd = join(' ', map { quotemeta } $^X, $script, @args) . " 2>&1";
    my $out = qx($cmd);
    return ( $? >> 8, $out );
}

sub fixture_manifest {
    my ( $dir, %opts ) = @_;
    my @files = @{ $opts{files} // [] };
    my @mfiles;
    for my $f (@files) {
        write_file( "$dir/$f->{path}", $f->{content} );
        push @mfiles,
            {
            path       => $f->{path},
            install_to => $f->{install_to},
            bucket     => $f->{bucket} // 'code',
            sha256     => sha256_hex( $f->{content} ),
            size       => length( $f->{content} ),
            };
    }
    write_json(
        "$dir-manifest.json",
        {
            schema_version   => '1',
            version          => $opts{version} // '1.2.3',
            min_upgrade_from => $opts{version} // '1.2.3',
            generated        => '2026-04-21T00:00:00Z',
            files            => \@mfiles,
            runtime_paths    => [],
        }
    );
}

sub fixture_deps {
    my ( $path, %opts ) = @_;
    my $modules = $opts{modules} // {
        'Digest::SHA' => { core => JSON::PP::true, license => 'Artistic-1.0-Perl',
                           used_by => 'hashing' },
    };
    my $environment = $opts{environment} // [
        { name => 'perl', description => 'Perl',
          external_refs => [ { type => 'distribution',
                               url  => 'https://example.com/perl' } ] },
    ];
    write_json(
        $path,
        { schema_version => '1', modules => $modules, environment => $environment }
    );
}

# --- 1. Happy path ---

subtest 'happy path: top-level shape' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    fixture_manifest( $dir,
        files => [
            { path => 'bin/foo.pl', content => "use Digest::SHA;\n",
              install_to => '{CGIBIN}/foo.pl', bucket => 'code' },
        ],
    );
    fixture_deps("$dir-deps.json");

    my ( $rc, $out ) = run_script(
        '--manifest', "$dir-manifest.json",
        '--deps',     "$dir-deps.json",
        '--version',  '0.0.1',
        '--out',      "$dir-sbom.json",
    );
    is( $rc, 0, 'exit 0' ) or diag $out;

    open my $fh, '<', "$dir-sbom.json" or die $!;
    my $s = decode_json( do { local $/; <$fh> } );
    close $fh;
    is( $s->{bomFormat},        'CycloneDX', 'bomFormat' );
    is( $s->{specVersion},      '1.6',       'specVersion' );
    like( $s->{serialNumber}, qr/^urn:uuid:[0-9a-f-]{36}$/, 'serial looks like urn:uuid' );
    is( $s->{metadata}{component}{name},    'lazysite', 'component name' );
    is( $s->{metadata}{component}{version}, '0.0.1',    'component version' );
};

# --- 2. Each manifest file becomes a source component ---

subtest 'manifest files appear as source components with matching sha' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my $body = "use Digest::SHA;\n";
    fixture_manifest( $dir,
        files => [
            { path => 'bin/foo.pl', content => $body,
              install_to => '{CGIBIN}/foo.pl', bucket => 'code' },
        ],
    );
    fixture_deps("$dir-deps.json");

    run_script(
        '--manifest', "$dir-manifest.json",
        '--deps',     "$dir-deps.json",
        '--out',      "$dir-sbom.json",
    );
    open my $fh, '<', "$dir-sbom.json" or die $!;
    my $s = decode_json( do { local $/; <$fh> } );
    close $fh;
    my ($src) = grep {
        ref $_->{hashes} eq 'ARRAY'
          && $_->{hashes}[0]{content} eq sha256_hex($body)
    } @{ $s->{components} };
    ok( $src, 'source component with matching SHA present' );
    is( $src->{name},        'foo.pl', 'source name is basename' );
    is( $src->{hashes}[0]{alg}, 'SHA-256', 'hash algorithm' );
};

# --- 3. Deps become library components ---

subtest 'each dep becomes a library component' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    fixture_manifest( $dir,
        files => [
            { path => 'bin/foo.pl', content => "use Digest::SHA;\nuse URI;\n",
              install_to => '{CGIBIN}/foo.pl' },
        ],
    );
    fixture_deps( "$dir-deps.json",
        modules => {
            'Digest::SHA' => { core => JSON::PP::true,
                               license => 'Artistic-1.0-Perl', used_by => 'h' },
            'URI'         => { core => JSON::PP::false,
                               license => 'Artistic-1.0-Perl',
                               debian_pkg => 'liburi-perl', used_by => 'p' },
        },
    );
    run_script(
        '--manifest', "$dir-manifest.json",
        '--deps',     "$dir-deps.json",
        '--out',      "$dir-sbom.json",
    );
    open my $fh, '<', "$dir-sbom.json" or die $!;
    my $s = decode_json( do { local $/; <$fh> } );
    close $fh;
    my @libs = grep {
        $_->{type} eq 'library'
          && ( $_->{purl} // '' ) =~ /^pkg:cpan\//
    } @{ $s->{components} };
    is( scalar @libs, 2, 'two CPAN-purl components' );
    my %by_name = map { $_->{name} => $_ } @libs;
    is( $by_name{'URI'}{purl}, 'pkg:cpan/URI', 'URI purl' );
    is( $by_name{'Digest::SHA'}{purl}, 'pkg:cpan/Digest-SHA', '::-to-- in purl' );
};

# --- 4. Environment entries appear ---

subtest 'environment entries appear in components' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    fixture_manifest( $dir,
        files => [
            { path => 'bin/foo.pl', content => "use Digest::SHA;\n",
              install_to => '{CGIBIN}/foo.pl' },
        ],
    );
    fixture_deps("$dir-deps.json");

    run_script(
        '--manifest', "$dir-manifest.json",
        '--deps',     "$dir-deps.json",
        '--out',      "$dir-sbom.json",
    );
    open my $fh, '<', "$dir-sbom.json" or die $!;
    my $s = decode_json( do { local $/; <$fh> } );
    close $fh;
    my ($env) = grep {
        $_->{name} eq 'perl' && $_->{type} eq 'application'
    } @{ $s->{components} };
    ok( $env, 'perl environment entry present' );
    is( $env->{externalReferences}[0]{type}, 'distribution', 'external ref type' );
};

# --- 5. --strict passes when all modules listed ---

subtest '--strict passes when all code modules are in sbom-deps' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    fixture_manifest( $dir,
        files => [
            { path => 'bin/foo.pl',
              content => "use strict;\nuse Digest::SHA qw(sha256_hex);\n",
              install_to => '{CGIBIN}/foo.pl' },
        ],
    );
    fixture_deps("$dir-deps.json");

    my ( $rc, $out ) = run_script(
        '--manifest', "$dir-manifest.json",
        '--deps',     "$dir-deps.json",
        '--staged',   $dir,
        '--out',      "$dir-sbom.json",
        '--strict',
    );
    is( $rc, 0, '--strict exit 0 when all listed' ) or diag $out;
};

# --- 6. --strict fails when a module is missing ---

subtest '--strict fails when a module is not in sbom-deps' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    fixture_manifest( $dir,
        files => [
            { path => 'bin/foo.pl',
              content => "use Digest::SHA;\nuse Mystery::Module;\n",
              install_to => '{CGIBIN}/foo.pl' },
        ],
    );
    fixture_deps("$dir-deps.json");   # only lists Digest::SHA

    my ( $rc, $out ) = run_script(
        '--manifest', "$dir-manifest.json",
        '--deps',     "$dir-deps.json",
        '--staged',   $dir,
        '--out',      "$dir-sbom.json",
        '--strict',
    );
    isnt( $rc, 0, '--strict non-zero exit' );
    like( $out, qr/Mystery::Module/, 'missing module named in error' );
};

# --- 7. Pragmas ignored ---

subtest 'pragmas not flagged as missing deps' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    fixture_manifest( $dir,
        files => [
            { path => 'bin/foo.pl',
              content => "use strict;\nuse warnings;\nuse feature 'say';\n"
                       . "use parent 'Exporter';\nuse utf8;\n"
                       . "use Digest::SHA;\n",
              install_to => '{CGIBIN}/foo.pl' },
        ],
    );
    fixture_deps("$dir-deps.json");

    my ( $rc, $out ) = run_script(
        '--manifest', "$dir-manifest.json",
        '--deps',     "$dir-deps.json",
        '--staged',   $dir,
        '--out',      "$dir-sbom.json",
        '--strict',
    );
    is( $rc, 0, 'pragmas did not trigger failure' )
        or diag $out;
};

# --- 8. Unused sbom-deps entry is noted but not failing ---

subtest '--strict notes unused sbom-deps entries but does not fail' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    fixture_manifest( $dir,
        files => [
            { path => 'bin/foo.pl',
              content => "use Digest::SHA;\n",
              install_to => '{CGIBIN}/foo.pl' },
        ],
    );
    fixture_deps( "$dir-deps.json",
        modules => {
            'Digest::SHA' => { core => JSON::PP::true,
                               license => 'Artistic-1.0-Perl', used_by => 'h' },
            'Leftover::Module' => { core => JSON::PP::false,
                                    license => 'Artistic-1.0-Perl',
                                    used_by => 'noone' },
        },
    );

    my ( $rc, $out ) = run_script(
        '--manifest', "$dir-manifest.json",
        '--deps',     "$dir-deps.json",
        '--staged',   $dir,
        '--out',      "$dir-sbom.json",
        '--strict',
    );
    is( $rc, 0, 'unused entries do not fail' );
    like( $out, qr/Leftover::Module/, 'unused entry mentioned' );
};

# --- 9. UUID is well-formed v4 ---

subtest 'serialNumber is valid UUID v4' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    fixture_manifest( $dir,
        files => [
            { path => 'bin/foo.pl', content => "use Digest::SHA;\n",
              install_to => '{CGIBIN}/foo.pl' },
        ],
    );
    fixture_deps("$dir-deps.json");

    run_script(
        '--manifest', "$dir-manifest.json",
        '--deps',     "$dir-deps.json",
        '--out',      "$dir-sbom.json",
    );
    open my $fh, '<', "$dir-sbom.json" or die $!;
    my $s = decode_json( do { local $/; <$fh> } );
    close $fh;
    # UUID v4: xxxxxxxx-xxxx-4xxx-[89ab]xxx-xxxxxxxxxxxx
    like( $s->{serialNumber},
          qr/^urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
          'UUID v4 shape (version nibble 4, variant nibble 8/9/a/b)' );
};

done_testing();
