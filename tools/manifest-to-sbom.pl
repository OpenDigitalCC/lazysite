#!/usr/bin/perl
# tools/manifest-to-sbom.pl - generate CycloneDX 1.6 sbom.json from
# release-manifest.json + dist/config/sbom-deps.json. Core-only Perl.
#
# In --strict mode, greps every shipped .pl/.pm for use/require and
# aborts if any module is missing from sbom-deps.json. This is the
# gate that prevents SBOM drift: a new dependency cannot ship until
# its metadata is added.
use strict;
use warnings;
use Digest::SHA qw();
use JSON::PP qw();
use POSIX qw(strftime);
use Getopt::Long qw();
use FindBin qw();
use File::Basename qw(dirname basename);

my %opt = (
    manifest => undef,
    deps     => undef,
    version  => undef,
    out      => undef,
    strict   => 0,
    staged   => undef,
    help     => 0,
);
Getopt::Long::GetOptions(
    'manifest=s' => \$opt{manifest},
    'deps=s'     => \$opt{deps},
    'version=s'  => \$opt{version},
    'out=s'      => \$opt{out},
    'strict'     => \$opt{strict},
    'staged=s'   => \$opt{staged},
    'help'       => \$opt{help},
) or die usage();
print usage() and exit 0 if $opt{help};

my $REPO_ROOT = find_repo_root();
$opt{manifest} //= "$REPO_ROOT/release-manifest.json";
$opt{deps}     //= "$REPO_ROOT/dist/config/sbom-deps.json";
$opt{out}      //= "$REPO_ROOT/sbom.json";
$opt{staged}   //= $REPO_ROOT;

my $PRAGMAS = { map { $_ => 1 } qw(
    strict warnings utf8 feature lib constant
    parent base vars overloading bignum bigint open
    subs integer locale bytes if sigtrap diagnostics
    autodie autouse blib encoding fields less charnames
    CORE version re mro
) };

exit main();

# -------- top level --------

sub usage {
    return <<'USAGE';
tools/manifest-to-sbom.pl - generate CycloneDX 1.6 sbom.json

Usage:
    tools/manifest-to-sbom.pl [options]

Options:
    --manifest PATH   Release manifest (default: release-manifest.json)
    --deps PATH       Curated deps metadata (default: dist/config/sbom-deps.json)
    --version VER     Version for the component (default: from manifest)
    --out PATH        Output path (default: sbom.json at repo root)
    --strict          Grep code for use/require and fail if any module
                      is missing from sbom-deps.json
    --staged PATH     Root under which to grep (default: repo root)
    --help            Show this help
USAGE
}

sub main {
    my $manifest = load_json( $opt{manifest} );
    my $deps     = load_json( $opt{deps} );
    my $version  = $opt{version} // $manifest->{version} // '0.0.0';

    if ( $opt{strict} ) {
        my $rc = strict_check( $manifest, $deps );
        return $rc if $rc != 0;
    }

    my $sbom = build_sbom( $manifest, $deps, $version );
    write_canonical_json( $opt{out}, $sbom );
    print STDERR "manifest-to-sbom: wrote $opt{out} ("
      . scalar( @{ $sbom->{components} } ) . " components)\n";
    return 0;
}

# -------- strict grep check --------

sub strict_check {
    my ( $manifest, $deps ) = @_;

    my %listed = map { $_ => 1 } keys %{ $deps->{modules} // {} };
    my %found;

    for my $f ( @{ $manifest->{files} // [] } ) {
        next unless $f->{path} =~ /\.p[lm]$/;
        my $full = "$opt{staged}/$f->{path}";
        next unless -f $full;
        open my $fh, '<', $full or next;
        while ( my $line = <$fh> ) {
            next if $line =~ /^\s*#/;
            # SM059: anchor the use/require match to statement
            # boundaries. The previous `\b(use|require)` regex
            # captured "use D013" inside a string literal like
            # 'repo must use D013 nested shape' (D013 error-
            # message text), so the false positive blocked
            # releases. The new regex requires start-of-line,
            # a preceding `;` (same-line chained statements),
            # or a `{` (block-opening, for patterns like
            # `eval { require Module; 1 }`). Each is a real
            # Perl statement boundary; none occur inside a
            # string literal mid-line.
            while ( $line =~ /(?:^|[{;])\s*(?:use|require)\s+([A-Z][\w:]*)/g ) {
                my $mod = $1;
                next if $PRAGMAS->{$mod};
                $found{$mod}++;
            }
        }
        close $fh;
    }

    my @missing = sort grep { !$listed{$_} } keys %found;
    if ( @missing ) {
        print STDERR "manifest-to-sbom --strict: modules in code but "
          . "missing from sbom-deps.json:\n";
        print STDERR "  $_\n" for @missing;
        print STDERR "Add entries to dist/config/sbom-deps.json and re-run.\n";
        return 1;
    }

    my @unused = sort grep { !$found{$_} } keys %listed;
    if ( @unused ) {
        print STDERR "manifest-to-sbom: sbom-deps entries with no use in code "
          . "(may be conditional or prunable):\n";
        print STDERR "  $_\n" for @unused;
    }
    return 0;
}

# -------- SBOM build --------

sub build_sbom {
    my ( $manifest, $deps, $version ) = @_;

    my $uuid      = gen_uuid_v4();
    my $timestamp = strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime );

    my @components;

    # Source components - one per manifest file.
    for my $f ( @{ $manifest->{files} // [] } ) {
        my $name  = basename( $f->{path} );
        my $type  = ( $f->{path} =~ /\.pm$/ ) ? 'library' : 'file';
        my $purl  = 'pkg:generic/opendigital/' . uri_escape_path( $f->{path} ) . '@' . $version;
        my %props = (
            'lazysite:category' => 'source',
            'lazysite:bucket'   => $f->{bucket} // 'unknown',
            'lazysite:path'     => $f->{path},
        );
        $props{'lazysite:install_to'} = $f->{install_to} if defined $f->{install_to};

        push @components, {
            type     => $type,
            name     => $name,
            version  => $version,
            hashes   => [ { alg => 'SHA-256', content => $f->{sha256} } ],
            licenses => [ { license => { id => 'Artistic-1.0-Perl' } } ],
            purl     => $purl,
            properties => [ map { { name => $_, value => $props{$_} } }
                              sort keys %props ],
        };
    }

    # Dependency components - one per sbom-deps entry.
    for my $modname ( sort keys %{ $deps->{modules} // {} } ) {
        my $m    = $deps->{modules}{$modname};
        my $purl = 'pkg:cpan/' . ( $modname =~ s/::/-/gr );
        my %props = (
            'lazysite:category' => 'dependency',
            'lazysite:core'     => $m->{core} ? 'true' : 'false',
        );
        $props{'lazysite:debian_pkg'} = $m->{debian_pkg} if defined $m->{debian_pkg} && length $m->{debian_pkg};
        $props{'lazysite:rhel_pkg'}   = $m->{rhel_pkg}   if defined $m->{rhel_pkg}   && length $m->{rhel_pkg};
        $props{'lazysite:alpine_pkg'} = $m->{alpine_pkg} if defined $m->{alpine_pkg} && length $m->{alpine_pkg};
        $props{'lazysite:used_by'}    = $m->{used_by}    if defined $m->{used_by}    && length $m->{used_by};

        my $entry = {
            type    => 'library',
            'bom-ref' => $purl,
            name    => $modname,
            version => 'unknown',
            purl    => $purl,
            properties => [ map { { name => $_, value => $props{$_} } }
                              sort keys %props ],
        };
        $entry->{licenses} = [ { license => { id => $m->{license} } } ]
            if defined $m->{license} && length $m->{license};
        push @components, $entry;
    }

    # Environment components.
    for my $env ( @{ $deps->{environment} // [] } ) {
        my $entry = {
            type    => 'application',
            name    => $env->{name},
            version => 'unknown',
            properties => [
                { name => 'lazysite:category', value => 'environment' },
            ],
        };
        $entry->{description} = $env->{description} if defined $env->{description};
        if ( $env->{external_refs} && @{ $env->{external_refs} } ) {
            $entry->{externalReferences} = [
                map { { type => $_->{type}, url => $_->{url} } }
                    @{ $env->{external_refs} }
            ];
        }
        push @components, $entry;
    }

    return {
        bomFormat    => 'CycloneDX',
        specVersion  => '1.6',
        serialNumber => "urn:uuid:$uuid",
        version      => 1,
        metadata     => {
            timestamp => $timestamp,
            tools     => [
                { name => 'manifest-to-sbom.pl', version => $version },
            ],
            component => {
                type        => 'application',
                name        => 'lazysite',
                version     => $version,
                description => 'Markdown-driven CGI site processor',
                licenses    => [ { license => { id => 'Artistic-1.0-Perl' } } ],
                externalReferences => [
                    { type => 'vcs',
                      url  => 'https://github.com/OpenDigitalCC/lazysite' },
                ],
            },
        },
        components => \@components,
    };
}

# -------- helpers --------

sub load_json {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "Cannot read $path: $!\n";
    my $text = do { local $/; <$fh> };
    close $fh;
    return JSON::PP::decode_json($text);
}

sub write_canonical_json {
    my ( $path, $data ) = @_;
    my $json = JSON::PP->new->utf8(1)->pretty(1)->indent_length(2)->canonical(1)->encode($data);
    open my $fh, '>:raw', $path or die "Cannot write $path: $!\n";
    print $fh $json;
    close $fh or die "Cannot close $path: $!\n";
}

sub gen_uuid_v4 {
    open my $fh, '<:raw', '/dev/urandom'
        or die "Cannot open /dev/urandom: $!\n";
    my $got = read $fh, my $bytes, 16;
    close $fh;
    die "Short read from /dev/urandom\n" unless defined $got && $got == 16;
    my @b = unpack 'C16', $bytes;
    # Version 4 (random): byte 6 high nibble = 4
    $b[6] = ( $b[6] & 0x0f ) | 0x40;
    # Variant RFC 4122: byte 8 high two bits = 10
    $b[8] = ( $b[8] & 0x3f ) | 0x80;
    return sprintf '%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x', @b;
}

sub uri_escape_path {
    my ($path) = @_;
    $path =~ s/([^A-Za-z0-9\-._~\/])/sprintf('%%%02X', ord($1))/ge;
    return $path;
}

sub find_repo_root {
    my $dir = $FindBin::Bin;
    for ( 1 .. 6 ) {
        return $dir if -d "$dir/starter"
            && ( -f "$dir/VERSION" || -f "$dir/NEXT_VERSION" );
        $dir = dirname($dir);
        last if $dir eq '/';
    }
    return dirname( $FindBin::Bin );
}
