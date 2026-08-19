#!/usr/bin/perl
# tools/build-manifest.pl - generate release-manifest.json from the
# repo or a staged release tree, using rules in
# dist/config/classification.json. Core-only Perl; no CPAN deps.
#
# Produces deterministic output: two runs on the same tree yield
# byte-identical JSON (modulo the "generated" timestamp).
use strict;
use warnings;
use Digest::SHA    qw();
use JSON::PP       qw();
use File::Find     qw();
use File::Basename qw(dirname basename);
use POSIX          qw(strftime);
use Getopt::Long   qw();
use FindBin        qw();

my %opt = (
    staged            => undef,
    version           => undef,
    out               => undef,
    check             => 0,
    config            => undef,
    channel           => undef,
    commit            => undef,    # SM400
    gate_files        => undef,    # SM400
    gate_tests        => undef,    # SM400
    security_critical => 0,
    help              => 0,
);
Getopt::Long::GetOptions(
    'staged=s'          => \$opt{staged},
    'version=s'         => \$opt{version},
    'out=s'             => \$opt{out},
    'check'             => \$opt{check},
    'config=s'          => \$opt{config},
    'channel=s'         => \$opt{channel},
    'commit=s'          => \$opt{commit},              # SM400
    'gate-files=i'      => \$opt{gate_files},          # SM400
    'gate-tests=i'      => \$opt{gate_tests},          # SM400
    'security-critical' => \$opt{security_critical},
    'help'              => \$opt{help},
) or die usage();
print usage() and exit 0 if $opt{help};

my $REPO_ROOT = find_repo_root();
$opt{config}  //= "$REPO_ROOT/dist/config/classification.json";
$opt{staged}  //= $REPO_ROOT;
$opt{out}     //= "$REPO_ROOT/release-manifest.json";
$opt{version} //= read_version_file();
# Release channel ladder - the build's maturity declaration: 'edge' (every
# release, early testing - the default), 'beta' (bedded-in candidate, cut
# with --channel beta / release.sh --beta), 'stable' (certified customer
# rollout, cut with --channel stable / release.sh --final). A site's
# update_channel is the minimum maturity it accepts (see install.pl).
$opt{channel} //= 'edge';
die "build-manifest: --channel must be 'edge', 'beta' or 'stable'\n"
    unless $opt{channel} =~ /^(?:edge|beta|stable)$/;

if ( $opt{check} ) {
    exit check_manifest();
} else {
    exit generate_manifest();
}

# -------- helpers --------

sub usage {
    return <<'USAGE';
tools/build-manifest.pl - generate release-manifest.json

Usage:
    tools/build-manifest.pl [options]

Options:
    --staged PATH    Root to scan (default: repo root)
    --version VER    Version for manifest (default: VERSION file)
    --out PATH       Output path (default: release-manifest.json at repo root)
    --config PATH    Classification config (default: dist/config/classification.json)
    --check          Verify manifest matches disk; exit 1 on mismatch
    --security-critical
                     Mark this release security-critical in the manifest
                     ("security_critical": true). Lets `lazysite upgrade
                     --all --force-security` override site channel/policy
                     for this release. Default: absent (not critical).
    --help           Show this help

USAGE
}

sub find_repo_root {
    # Walk up from this script's location until we see both a VERSION
    # file and a starter/ directory (the repo markers).
    my $dir = $FindBin::Bin;
    for ( 1 .. 6 ) {
        return $dir if -d "$dir/starter" && ( -f "$dir/VERSION" || -f "$dir/NEXT_VERSION" );
        $dir = dirname($dir);
        last if $dir eq '/';
    }
    # Fall back to parent of tools/
    return dirname($FindBin::Bin);
}

sub read_version_file {
    my $path = "$REPO_ROOT/VERSION";
    return '0.0.0' unless -f $path;
    open my $fh, '<', $path or return '0.0.0';
    chomp( my $v = <$fh> );
    close $fh;
    $v //= '';
    $v =~ s/^\s+|\s+$//g;
    return $v || '0.0.0';
}

sub load_config {
    my $path = shift;
    open my $fh, '<:raw', $path or die "Cannot read $path: $!\n";
    my $text = do { local $/; <$fh> };
    close $fh;
    my $cfg = JSON::PP::decode_json($text);
    for my $key (qw(rules exclude overrides runtime_paths runtime_files install_dirs)) {
        $cfg->{$key} //= [];
    }
    return $cfg;
}

sub scan_files {
    my ($root) = @_;
    my @out;
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                return unless -f $_;
                my $rel = $_;
                $rel =~ s{^\Q$root\E/?}{};
                return unless length $rel;
                push @out, $rel;
            },
        },
        $root,
    );
    @out = sort @out;
    return \@out;
}

sub sha256_of {
    my ($path) = @_;
    my $sha = Digest::SHA->new('sha256');
    $sha->addfile( $path, 'b' );
    return $sha->hexdigest;
}

sub classify_file {
    my ( $rel, $cfg ) = @_;

    # SM271: a DOTFILE at the repo ROOT is tooling state, not shippable content.
    #
    # This gate refuses any file matching no rule, which is right for ordinary
    # content - an unclassified file is one nobody decided about, and shipping
    # it, or silently omitting it, is how a release acquires something nobody
    # reviewed. It is wrong for the repo root, which is where per-run tooling
    # state conventionally goes.
    #
    # Three tools tripped it in one session, none of them carelessly: `.prove`
    # (from `prove --state=save`), a test lockfile, and `.test_info.<pid>.json`
    # (written by yath, one per job, deleted a fraction of a second later). Six
    # tests build a manifest at the repo root, so each of those failed all six -
    # with an error naming the manifest rather than the file. Twice it presented
    # as a parallel-safety problem and once as harness incompatibility, and it
    # produced one confident wrong diagnosis before being caught.
    #
    # Deliberately narrow: ROOT only, and DOTFILES only. An unclassified
    # ordinary file still refuses, which is the case the strictness exists for,
    # and nothing lazysite ships is a root dotfile (t/tools/01 pins that).
    return { excluded => 1, reason => 'root dotfile (tooling state)' }
        if $rel =~ m{\A\.[^/]*\z};

    for my $pat ( @{ $cfg->{exclude} } ) {
        return { excluded => 1, reason => "exclude $pat" } if $rel =~ /$pat/;
    }

    for my $o ( @{ $cfg->{overrides} } ) {
        next unless defined $o->{path} && $o->{path} eq $rel;
        return {
            install_to => apply_install_to( $o->{install_to}, $rel ),
            bucket     => $o->{bucket},
        };
    }

    for my $r ( @{ $cfg->{rules} } ) {
        my $pat = $r->{pattern};
        next unless defined $pat;
        if ( my @caps = ( $rel =~ /$pat/ ) ) {
            my @values  = ( $rel, @caps );    # $0 = whole string, $1..$n = captures
            my $install = apply_captures( $r->{install_to}, \@values );
            return {
                install_to => $install,
                bucket     => $r->{bucket},
            };
        }
    }
    return { unmatched => 1 };
}

sub apply_captures {
    my ( $template, $values ) = @_;
    return undef unless defined $template;
    my $out = $template;
    # Substitute $0..$9 with corresponding captures. $0 is the full match.
    $out =~ s/\$(\d)/defined $values->[$1] ? $values->[$1] : ''/ge;
    return $out;
}

sub apply_install_to {
    my ( $install_to, $rel ) = @_;
    return undef unless defined $install_to;
    # For override entries with a static install_to, no capture replacement.
    # If the string contains $0 as a convenience, replace with $rel.
    my $out = $install_to;
    $out =~ s/\$0/$rel/g;
    return $out;
}

sub generate_manifest {
    my $cfg   = load_config( $opt{config} );
    my $files = scan_files( $opt{staged} );

    my @manifest_files;
    my @unmatched;
    my %install_to_seen;

    for my $rel (@$files) {
        my $cls = classify_file( $rel, $cfg );
        next if $cls->{excluded};
        if ( $cls->{unmatched} ) {
            push @unmatched, $rel;
            next;
        }

        my $install = $cls->{install_to};
        if ( defined $install && $install =~ /\Q..\E/ ) {
            # {DOCROOT}/../tools/... is a deliberate docroot-parent placement
            # used by lazysite-log.pl and the tools/ scripts. Accept it only
            # when the ".." is bounded by a path separator and immediately
            # preceded by the {DOCROOT} placeholder or {CGIBIN} placeholder.
            my $stripped = $install;
            $stripped =~ s{\{DOCROOT\}/\.\./}{/};
            $stripped =~ s{\{CGIBIN\}/\.\./}{/};
            if ( $stripped =~ m{/\.\./} || $stripped =~ m{^\.\./} ) {
                die "Install path contains stray '..': $install (from $rel)\n";
            }
        }

        if ( defined $install ) {
            if ( $install_to_seen{$install} ) {
                die "Duplicate install_to '$install': $rel "
                    . "collides with $install_to_seen{$install}\n";
            }
            $install_to_seen{$install} = $rel;
        }

        my $full = "$opt{staged}/$rel";
        my @st   = stat $full;
        push @manifest_files, {
            path       => $rel,
            install_to => $install,
            bucket     => $cls->{bucket},
            sha256     => sha256_of($full),
            size       => 0 + ( $st[7] // 0 ),
        };
    }

    if (@unmatched) {
        # SM271: lead with the file. The old wording named the manifest, two
        # layers from the cause, and readers reliably diagnosed the wrong thing.
        my $n = @unmatched;
        print STDERR "build-manifest: REFUSING - $n unclassified file(s):\n";
        print STDERR "  $_\n" for @unmatched;
        # SM034: use the actual config path in use so the message is
        # accurate regardless of the --config override. The path
        # moved to dist/config/classification.json during D021a/b.
        print STDERR "Add a rule or exclude to $opt{config}.\n";
        return 1;
    }

    # Sort: files without install_to go last; otherwise by install_to.
    @manifest_files = sort {
        my $ai = defined $a->{install_to} ? 0 : 1;
        my $bi = defined $b->{install_to} ? 0 : 1;
        $ai <=> $bi
            || ( $a->{install_to} // '' ) cmp( $b->{install_to} // '' )
            || $a->{path} cmp $b->{path};
    } @manifest_files;

    my $manifest = {
        schema_version   => '1',
        version          => $opt{version},
        min_upgrade_from => $opt{version},
        channel          => $opt{channel},
        generated        => strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime ),
        files            => \@manifest_files,
        runtime_paths    => $cfg->{runtime_paths},
        # SM246: the permission model has ONE table, and the installer reads it
        # from the manifest - so every section of that table has to be CARRIED
        # by the manifest. runtime_files was declared in classification.json and
        # read by install.pl, but never emitted here, so install fell through to
        # its hardcoded fallback on every build and the declaration was inert.
        # A model the consumer cannot see is not a model.
        runtime_files => $cfg->{runtime_files},
        install_dirs  => $cfg->{install_dirs},
    };
    # SM139: a security-critical release declares itself in the manifest; the
    # field is present only when set, so ordinary manifests are unchanged.
    $manifest->{security_critical} = JSON::PP::true() if $opt{security_critical};

    # SM400: THE ARTEFACT ATTESTS ITS OWN GATE.
    #
    # A promotion review could establish which VERSION was being proposed and
    # not which COMMIT had been validated, because the gate's summary went to a
    # terminal and an untracked file. "The build that would go to beta is not
    # the build that was validated" was a reasonable conclusion and nobody could
    # cheaply disprove it.
    #
    # There is no `result` field. release.sh exits before this line if the gate
    # fails, so the only value it could ever hold is PASS - and a field that can
    # only say one thing reads as evidence while carrying none.
    #
    # Present only when supplied, exactly as security_critical is, so a manifest
    # built by hand or by --check is unchanged. --check compares the files array
    # against disk and never looks at the top-level keys, so this cannot make a
    # rebuilt manifest disagree with a shipped one.
    $manifest->{validated} = {
        commit => $opt{commit},
        files  => $opt{gate_files} + 0,
        tests  => $opt{gate_tests} + 0,
    } if defined $opt{commit} && defined $opt{gate_files} && defined $opt{gate_tests};

    write_canonical_json( $opt{out}, $manifest );
    print STDERR "build-manifest: wrote $opt{out} (" . scalar(@manifest_files) . " files)\n";
    return 0;
}

sub check_manifest {
    my $manifest_path = $opt{out};
    return report_check_fail("manifest not found: $manifest_path") unless -f $manifest_path;

    open my $fh, '<:raw', $manifest_path or return report_check_fail("Cannot read $manifest_path: $!");
    my $text = do { local $/; <$fh> };
    close $fh;
    my $manifest = eval { JSON::PP::decode_json($text) };
    return report_check_fail("Cannot parse $manifest_path: $@") if $@;

    my $cfg   = load_config( $opt{config} );
    my $files = scan_files( $opt{staged} );

    my %by_path = map { $_->{path} => $_ } @{ $manifest->{files} || [] };

    my @missing;
    my @size_mismatch;
    my @sha_mismatch;
    my @not_in_manifest;

    for my $rel (@$files) {
        my $cls = classify_file( $rel, $cfg );
        next if $cls->{excluded};
        next if $cls->{unmatched};
        unless ( $by_path{$rel} ) {
            push @not_in_manifest, $rel;
            next;
        }
        my $entry = $by_path{$rel};
        my $full  = "$opt{staged}/$rel";
        my @st    = stat $full;
        unless (@st) {
            push @missing, $rel;
            next;
        }
        my $size = 0 + ( $st[7] // 0 );
        if ( $size != ( $entry->{size} // -1 ) ) {
            push @size_mismatch, "$rel (disk=$size manifest=$entry->{size})";
            next;
        }
        my $sha = sha256_of($full);
        if ( $sha ne ( $entry->{sha256} // '' ) ) {
            push @sha_mismatch, "$rel (disk=$sha manifest=$entry->{sha256})";
        }
    }

    for my $entry ( @{ $manifest->{files} || [] } ) {
        my $full = "$opt{staged}/$entry->{path}";
        push @missing, $entry->{path} unless -f $full;
    }

    if ( @missing || @size_mismatch || @sha_mismatch || @not_in_manifest ) {
        print STDERR "build-manifest --check: mismatches detected\n";
        print STDERR "  missing from disk:\n    $_\n" for @missing;
        print STDERR "  size mismatch:\n    $_\n"     for @size_mismatch;
        print STDERR "  sha256 mismatch:\n    $_\n"   for @sha_mismatch;
        print STDERR "  not in manifest:\n    $_\n"   for @not_in_manifest;
        return 1;
    }
    print STDERR "build-manifest --check: OK ("
        . scalar( @{ $manifest->{files} || [] } ) . " files)\n";
    return 0;
}

sub report_check_fail {
    my ($msg) = @_;
    print STDERR "build-manifest --check: $msg\n";
    return 1;
}

sub write_canonical_json {
    my ( $path, $data ) = @_;
    my $json = JSON::PP->new->utf8(1)->pretty(1)->indent_length(2)->canonical(1)->encode($data);
    open my $fh, '>:raw', $path or die "Cannot write $path: $!\n";
    print $fh $json;
    close $fh or die "Cannot close $path: $!\n";
}
