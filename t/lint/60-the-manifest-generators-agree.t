#!/usr/bin/perl
# SM304: two copies of _generate_manifest_to_tmp, and they have already drifted.
#
# `release-manifest.json` is generated at build time and gitignored, so it
# exists in a release tarball and not in a checkout. Three readers handle its
# absence, and two of them - install.pl and tools/manifest-to-sbom.pl - carry
# the same function under the same name, added the same day by the same change.
#
# ONE OWNER IS NOT AVAILABLE HERE, which is why this is a lint and not a
# refactor. install.pl is core-Perl-only by design: it must run BEFORE, and
# independently of, the engine it installs, so it cannot load a Lazysite module
# (the same constraint t/lint/51 records for the private-store path and
# t/lint/55 for the security headers). manifest-to-sbom.pl loads no modules
# either. A shared module would change the dependency posture of both to remove
# eleven lines.
#
# So the duplication stays and the DRIFT does not. When a fact must exist twice,
# this project asserts the second copy against the first rather than trusting it.
#
# AND IT HAD ALREADY STARTED. When this lint was written the two derived their
# root differently - dirname() in one, a regex in the other - which is harmless
# today and is exactly how the pair stops being a pair.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# NO STUBBING. Each copy is given a fake tree whose build-manifest.pl is a real
# script that records its own arguments and writes an output file - so the
# comparison is of what each actually RUNS, through a real system() call.
#
# The first version stubbed system() inside the evaluated package, which does
# not override a builtin, and then tried CORE::GLOBAL, which does but is
# fragile across an eval boundary. A fake builder is less machinery and tests
# more of the path.
sub extract {
    my ($file) = @_;
    open my $fh, '<', "$root/$file" or die "$file: $!";
    local $/;
    my $src = <$fh>;
    close $fh;
    my ($sub) = $src =~ /(\nsub _generate_manifest_to_tmp \{.*?\n\}\n)/s;
    return $sub;
}

my %SRC = (
    'install.pl'                => extract('install.pl'),
    'tools/manifest-to-sbom.pl' => extract('tools/manifest-to-sbom.pl'),
);

subtest 'both copies are present' => sub {
    ok( $SRC{$_}, "$_ carries _generate_manifest_to_tmp" ) for sort keys %SRC;
};

# Evaluated with system() stubbed, so the comparison is of what each would DO -
# which builder it runs, against which root - rather than of their text. Two
# copies that read differently and behave identically are fine; two that read
# alike and behave differently are the failure.
my %CALLED;
for my $file ( sort keys %SRC ) {
    next unless $SRC{$file};
    ( my $pkg = $file ) =~ s/[^A-Za-z]/_/g;
    $pkg = "Gen_$pkg";
    my $code = "package $pkg;
        use File::Basename qw(dirname);
        $SRC{$file}
        1;";
    eval $code or do { fail("could not evaluate $file: $@"); next };
}

subtest 'both derive the same tree from the same manifest path' => sub {
    my $tmpdir = tempdir( CLEANUP => 1 );
    mkdir "$tmpdir/$_" for qw(tools dist dist/config);
    open my $cf, '>', "$tmpdir/dist/config/classification.json" or die $!;
    print {$cf} "{}\n";
    close $cf;

    # A builder that records how it was called and produces a non-empty file,
    # so the caller's success path is exercised too.
    open my $bf, '>', "$tmpdir/tools/build-manifest.pl" or die $!;
    print {$bf} <<'BUILDER';
#!/usr/bin/perl
use strict; use warnings;
open my $log, '>>', "$ENV{MANIFEST_PROBE_LOG}" or die $!;
print {$log} join( ' ', @ARGV ), "\n";
close $log;
my ($out) = grep { $_ } map { $ARGV[$_+1] if $ARGV[$_] eq '--out' } 0..$#ARGV;
open my $o, '>', $out or die $!; print {$o} "{}\n"; close $o;
BUILDER
    close $bf;

    my %root_used;
    for my $file ( sort keys %SRC ) {
        ( my $pkg = $file ) =~ s/[^A-Za-z]/_/g;
        $pkg = "Gen_$pkg";
        no strict 'refs';
        my $fn = \&{"${pkg}::_generate_manifest_to_tmp"};
        next unless defined &$fn;

        my $log = "$tmpdir/probe.log";
        unlink $log;
        local $ENV{MANIFEST_PROBE_LOG} = $log;
        my $got = $fn->("$tmpdir/release-manifest.json");
        ok( $got, "$file produced a manifest" )
            or diag( 'it returned undef - it did not find the builder or the '
                . 'classification file where it looked' );
        unlink $got if $got;

        open my $lf, '<', $log or next;
        my $line = <$lf>;
        close $lf;
        chomp $line if defined $line;
        ( $root_used{$file} ) = ( $line // '' ) =~ /--staged\s+(\S+)/;
    }

    my @vals = map { $root_used{$_} } sort keys %root_used;
    cmp_ok( scalar( grep { defined } @vals ), '==', 2, 'both were exercised' )
        or return;
    is( $vals[0], $vals[1],
        'and both hand the builder the same tree' )
        or diag( "install.pl:       $vals[0]\n"
            . "manifest-to-sbom: $vals[1]\n"
            . 'These derive the root differently. Harmless while the shapes '
            . 'agree, and exactly how the pair stops being a pair.' );
};

subtest 'and they write to DIFFERENT temp files, deliberately' => sub {
    # The one difference that must NOT be normalised away. Two tools running at
    # once with the same PID-suffixed path would clobber each other's manifest,
    # and the symptom would be an SBOM describing somebody else's tree.
    my @tmps;
    for my $file ( sort keys %SRC ) {
        next unless $SRC{$file};
        my ($tmp) = $SRC{$file} =~ m{"(/tmp/[^"]*\$\$[^"]*)"};
        push @tmps, $tmp if defined $tmp;
    }
    is( scalar @tmps, 2, 'both name a temp path' ) or return;
    isnt( $tmps[0], $tmps[1],
        'and the two differ, so concurrent runs cannot clobber each other' )
        or diag( 'Both use "@{[$$]}" so a shared name collides only between '
            . 'processes - which is precisely the case here, since the '
            . 'installer and the SBOM tool can run in the same release.' );
};

done_testing();
