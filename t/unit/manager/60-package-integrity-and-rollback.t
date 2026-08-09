#!/usr/bin/perl
# SM183: a package carries an integrity digest, and an apply is reversible.
#
# INTEGRITY. A site package is the artefact that TRAVELS - an agency builds a
# demo and hands it to a client's own instance, often across organisations and by
# whatever channel is to hand. The receiving operator had no way to distinguish
# an altered package from an intact one, and applying it OVERWRITES a site. The
# release tarballs have carried a .sha256 sidecar for exactly this reason since
# long before site packages existed.
#
# A sidecar rather than a manifest field, deliberately: `sha256sum -c` verifies
# it with no lazysite tooling at all, which is the situation the receiving
# operator is actually in.
#
# ROLLBACK. The apply now snapshots on every surface and returns the name; this
# checks the other half - that the named snapshot actually restores the site.
# A snapshot nothing can restore is not a rollback point.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::SitePackage qw(package_create apply_and_configure);
use Lazysite::Manager::Backups     ();

sub spit  { open my $fh, '>', $_[0] or die $!;    print {$fh} $_[1]; close $fh }
sub slurp { open my $fh, '<', $_[0] or return ''; local $/;          <$fh> }

sub fixture {
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/lazysite/layouts/base", "$d/sites/clienta", "$d/sites/target" );
    spit(
        "$d/lazysite/lazysite.conf",
        "site_name: Agency\n"
            . "alias_hosts: shop.clienta.com, target.example\n"
            . "alias.shop.clienta.com.content_root: sites/clienta\n"
            . "alias.shop.clienta.com.layout: base\n"
            . "alias.target.example.content_root: sites/target\n"
    );
    spit( "$d/sites/clienta/index.md",          "# Client A\n" );
    spit( "$d/sites/target/index.md",           "# TARGET-ORIGINAL\n" );
    spit( "$d/lazysite/layouts/base/layout.tt", '[% content %]' );
    $Lazysite::Manager::SitePackage::DOCROOT   = $d;
    $Lazysite::Manager::SitePackage::auth_user = 'tester';
    $Lazysite::Manager::Backups::DOCROOT       = $d;
    $Lazysite::Manager::Backups::LAZYSITE_DIR  = "$d/lazysite";
    $Lazysite::Manager::Backups::auth_user     = 'tester';
    return $d;
}

# --- the package carries a digest -------------------------------------------
subtest 'package_create writes a verifiable sha256 sidecar' => sub {
    my $d = fixture();
    my $r = package_create('shop.clienta.com');
    ok( $r->{ok}, 'packaged' ) or diag $r->{error};

    my $pkg = "$d/lazysite/backups/$r->{name}";
    ok( -f "$pkg.sha256", 'the sidecar is written beside the package' );
    like( $r->{sha256}, qr/\A[0-9a-f]{64}\z/, 'and the digest is returned' );

    # sha256sum -c format: "<64 hex>  <basename>". The basename matters - a
    # sidecar naming a full path only verifies from the directory it was made in.
    my $line = slurp("$pkg.sha256");
    like( $line, qr/\A[0-9a-f]{64}  \Q$r->{name}\E\n\z/,
        'in sha256sum -c format, naming the BASENAME' );

    # And it is the digest of the actual bytes.
    my $want = `sha256sum \Q$pkg\E 2>/dev/null`;
    my ($expect) = $want =~ /\A([0-9a-f]{64})/;
SKIP: {
        skip 'sha256sum not available', 1 unless defined $expect;
        is( $r->{sha256}, $expect, 'the digest matches the file on disk' );
    }
};

# --- a backup carries one too ------------------------------------------------
subtest 'backup_create writes one, and backup_list surfaces it' => sub {
    my $d = fixture();
    my $b = Lazysite::Manager::Backups::action_backup_create('manual');
    ok( $b->{ok}, 'backup created' );
    like( $b->{sha256}, qr/\A[0-9a-f]{64}\z/, 'digest returned' );

    my $l = Lazysite::Manager::Backups::action_backup_list();
    my ($row) = grep { $_->{name} eq $b->{name} } @{ $l->{backups} };
    ok( $row, 'the backup is listed' );
    is( $row->{sha256}, $b->{sha256}, 'and the listing carries its digest' );

    # The sidecars must never be listed AS backups - they are not restorable.
    my @sidecars = grep { $_->{name} =~ /\.sha256\z/ } @{ $l->{backups} };
    is_deeply( \@sidecars, [], 'a sidecar is not itself listed as a backup' );
};

# --- an artefact from before this is unverified, not broken -----------------
subtest 'a package with no sidecar lists as unverified' => sub {
    my $d = fixture();
    my $b = Lazysite::Manager::Backups::action_backup_create('manual');
    unlink "$d/lazysite/backups/$b->{name}.sha256";

    my $l = Lazysite::Manager::Backups::action_backup_list();
    my ($row) = grep { $_->{name} eq $b->{name} } @{ $l->{backups} };
    is( $row->{sha256}, '',
        'empty rather than absent or an error - an older artefact is simply '
            . 'unverified, not one whose digest failed' );
};

# --- the rollback point actually restores ------------------------------------
# The apply returns a snapshot name. This is the half that makes it a rollback
# POINT rather than a file: restoring it must bring the overwritten site back.
subtest 'the snapshot an apply names restores the pre-apply site' => sub {
    my $d = fixture();
    my $r = package_create('shop.clienta.com');
    ok( $r->{ok}, 'packaged the source' ) or diag $r->{error};

    like( slurp("$d/sites/target/index.md"), qr/TARGET-ORIGINAL/,
        'the target has its own page before the apply' );

    my $ap = apply_and_configure( "$d/lazysite/backups/$r->{name}",
        host => 'target.example', clean => 1 );
    ok( $ap->{ok}, 'apply succeeded' ) or diag( $ap->{error} // '' );
    unlike( slurp("$d/sites/target/index.md"), qr/TARGET-ORIGINAL/,
        'and the apply replaced it' );

    ok( defined $ap->{safety} && length $ap->{safety}, 'a snapshot was named' );
    my $rs = Lazysite::Manager::Backups::action_backup_restore( $ap->{safety} );
    ok( $rs->{ok}, 'the named snapshot restores' ) or diag( $rs->{error} // '' );

    like( slurp("$d/sites/target/index.md"), qr/TARGET-ORIGINAL/,
        'and the pre-apply page is back - the rollback path works end to end' );
};

# --- two snapshots in the same second must not be the same snapshot ---------
# The name was lazysite-<kind>-<UTC seconds> and the stamp was the ONLY thing
# making it unique, so a second snapshot inside the same second overwrote the
# first and reported success.
#
# This is what broke the rollback above, and it is worth stating as its own test
# because the consequence is much wider than site packages: action_backup_restore
# takes a safety snapshot before restoring, so rolling an apply back promptly
# destroyed the very artefact being restored FROM, then "restored" the state the
# operator was trying to undo.
subtest 'backups taken in the same second do not overwrite each other' => sub {
    my $d = fixture();
    my $a = Lazysite::Manager::Backups::action_backup_create('manual');
    my $b = Lazysite::Manager::Backups::action_backup_create('manual');
    ok( $a->{ok} && $b->{ok}, 'both backups reported success' );

    isnt( $a->{name}, $b->{name},
        'and they are DIFFERENT files - a second-granular stamp is not a '
            . 'uniqueness guarantee' );
    ok( -f "$d/lazysite/backups/$a->{name}", 'the first still exists' );
    ok( -f "$d/lazysite/backups/$b->{name}", 'and so does the second' );

    # The disambiguator keeps lexical order stable, so listings and retention
    # sweeps still see them in the order they were taken.
    like( $b->{name}, qr/-\d+\.tar\.gz\z/, 'the later one carries the suffix' );

    # Their digests must describe their own bytes, not a shared sidecar.
    ok( -f "$d/lazysite/backups/$a->{name}.sha256", 'the first has its sidecar' );
    ok( -f "$d/lazysite/backups/$b->{name}.sha256", 'and the second has its own' );
};

done_testing();
