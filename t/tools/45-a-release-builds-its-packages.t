#!/usr/bin/perl
# SM372: a release builds its .deb set, and says so by naming the files.
#
# WHY THIS IS AUTOMATED RATHER THAN REMEMBERED. Packages exist in dist/ for
# every release up to 0.10.8 and then stop: 0.10.9, 0.10.10, 0.10.11, 0.10.12
# and 0.10.13 have none. Five releases, and nobody noticed - because release.sh
# succeeded without them and a step that is not part of a process that succeeds
# is a step that eventually stops happening.
#
# AND THE VERSION IS STAMPED, NOT READ. dpkg takes it from debian/changelog,
# which sat at 0.10.8-1 while the tree moved on - so building by hand today
# would have produced a package labelled 0.10.8 from 0.10.13 source. That is
# worse than a missing package: apt declines to upgrade to it, and `dpkg -l`
# tells an operator something false about what is installed. Generating the
# entry from $VERSION at release time makes the mislabelling impossible rather
# than merely detectable.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $src  = do {
    open my $fh, '<', "$root/tools/release.sh" or die $!;
    local $/;
    <$fh>;
};

subtest 'the release builds packages' => sub {
    like( $src, qr/build-deb\.sh/, 'release.sh runs build-deb.sh' )
        or diag( 'Without this the packages are a separate step somebody has '
            . 'to remember, which is how five releases went without them.' );
    like( $src, qr/LAZYSITE_SKIP_DEB/,
        'with an explicit opt-out rather than a silent skip' );
};

subtest 'and stamps the version rather than reading a stale file' => sub {
    my ($block) = $src =~ /(Stamping debian\/changelog.*?build-deb\.sh)/s;
    ok( $block, 'the changelog is stamped before the build' ) or return;
    like( $block, qr/\$VERSION/,
        'from the release version, so it cannot disagree with the tag' );
    like( $block, qr/\$STAGE\/debian\/changelog/,
        "and into the STAGE, leaving the repo's own file alone" );
};

subtest 'the success check is POSITIVE' => sub {
    # The distinction this whole release line is about. "dpkg-buildpackage
    # exited 0" is not "the packages exist at this version" - a build can
    # succeed and produce nothing, or produce the previous version's files,
    # and both would read as success against an exit status.
    my ($check) = $src =~ /(for pkg in .*?debian\/control.*?\n.*?\n.*?fi)/s;
    ok( $check, 'a per-package existence check runs after the build' ) or return;
    like( $check, qr/\$\{pkg\}_\$\{VERSION\}-1_all\.deb/,
        'naming each package AT THE RELEASE VERSION' )
        or diag( 'A check that looks for any .deb, or for the ones that were '
            . 'already there, passes on exactly the failure it is for.' );
    like( $src, qr/reported success and did not produce/,
        'and the failure says the build reported success, which is the point' );
};

subtest 'packages are built BEFORE the tag' => sub {
    # A failure here must abort a release that has not yet burned a version.
    my $deb = index( $src, 'build-deb.sh' );
    my $tag = index( $src, 'Tagging $TAG' );
    cmp_ok( $deb, '<', $tag, 'the build runs first' )
        or diag( 'Tagging first would leave a burned version with no packages, '
            . 'and burned versions are never reused (SM064).' );
};

subtest 'every package named in debian/control is checked' => sub {
    # Not a hard-coded list of four. A fifth package added to debian/control
    # must be checked without anyone editing release.sh.
    open my $cf, '<', "$root/debian/control" or die $!;
    my @pkgs = map { /^Package:\s*(\S+)/ } <$cf>;
    close $cf;
    cmp_ok( scalar @pkgs, '>=', 4, 'debian/control declares the package set' );
    like( $src, qr/awk '\/\^Package:\/ \{print \$2\}'/,
        'and release.sh reads that set rather than repeating it' );
};

done_testing();
