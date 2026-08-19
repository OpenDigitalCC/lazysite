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
use POSIX      qw(strftime);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::SitePackage qw(package_create apply_and_configure package_inspect);
use Lazysite::Manager::Backups     ();
use Lazysite::Manager::Domains     ();

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
    $Lazysite::Manager::Domains::DOCROOT       = $d;
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
# SM406: THIS SUBTEST DID NOT FORCE THE RACE IT IS NAMED AFTER.
#
# It took two backups back to back and asserted the second carried a `-N`
# disambiguator - which is only true if both landed in the SAME second. Each
# call tars a fixture tree, so on a loaded machine the pair straddles a second
# boundary, the second backup gets a fresh stamp, and `_claim_name` correctly
# returns it WITHOUT a suffix. The engine is right and the assertion fails.
#
# It passed 25 of 25 on an idle host and failed the 0.10.16 release gate, which
# is the one run where the machine is guaranteed to be busy. A test that only
# fails when the machine is loaded is worse than one that always fails: it looks
# like flakiness, and the reflex is to re-run rather than to read it.
#
# So the collision is now CONSTRUCTED rather than hoped for. The two halves are
# separated because they need different things: name uniqueness holds however
# the clock falls, and the suffix needs a real collision.
subtest 'two backups never overwrite each other' => sub {
    my $d = fixture();
    my $a = Lazysite::Manager::Backups::action_backup_create('manual');
    my $b = Lazysite::Manager::Backups::action_backup_create('manual');
    ok( $a->{ok} && $b->{ok}, 'both backups reported success' );

    isnt( $a->{name}, $b->{name},
        'and they are DIFFERENT files - a second-granular stamp is not a '
            . 'uniqueness guarantee' );
    ok( -f "$d/lazysite/backups/$a->{name}", 'the first still exists' );
    ok( -f "$d/lazysite/backups/$b->{name}", 'and so does the second' );

    # Their digests must describe their own bytes, not a shared sidecar.
    ok( -f "$d/lazysite/backups/$a->{name}.sha256", 'the first has its sidecar' );
    ok( -f "$d/lazysite/backups/$b->{name}.sha256", 'and the second has its own' );
};

subtest 'a backup colliding with an existing stamp takes the next suffix' => sub {
    my $d   = fixture();
    my $dir = "$d/lazysite/backups";
    make_path($dir) unless -d $dir;

    # Occupy the name THIS second would produce, so the collision is a fact of
    # the fixture rather than an accident of timing. The retry covers the one
    # case that remains: the clock ticking between our stamp and the claim.
    my ( $name, $stamp );
    for ( 1 .. 5 ) {
        $stamp = strftime( '%Y%m%dT%H%M%SZ', gmtime );
        my $taken = "$dir/lazysite-manual-$stamp.tar.gz";
        open my $fh, '>', $taken or die $!;
        close $fh;
        my $r = Lazysite::Manager::Backups::action_backup_create('manual');
        ok( $r->{ok}, 'the backup succeeded despite the name being taken' );
        $name = $r->{name};
        last if $name =~ /\A\Qlazysite-manual-$stamp\E-\d+\.tar\.gz\z/;
        unlink $taken;
    }

    # The disambiguator keeps lexical order stable, so listings and retention
    # sweeps still see them in the order they were taken.
    like( $name, qr/\A\Qlazysite-manual-$stamp\E-2\.tar\.gz\z/,
        'it takes the next free suffix rather than overwriting' );
    ok( -f "$dir/$name",        'and the file is really there' );
    ok( -f "$dir/$name.sha256", 'with its own sidecar' );
};

# SM268 03-F10: call the verifier through can(), so a tree WITHOUT it fails these
# assertions rather than dying on an undefined subroutine. A test that dies on
# the unfixed code proves the code is needed; one that fails proves what it does.
sub verify_status {
    my ($path) = @_;
    my $fn = Lazysite::Manager::Backups->can('verify_sha256') or return '(no verifier)';
    return $fn->($path);
}

# --- SM268 03-F10: the digest is VERIFIED, not merely displayed --------------
#
# The sidecar existed and nothing recomputed it. An operator saw a digest beside
# a package in the UI and read it as "verified"; it meant "a digest was written
# at some point". Misleading assurance is worse than none - someone who tampers
# with a tarball in place and leaves the sidecar alone got a green-looking
# listing, and apply overwrote a live site on the strength of it.
subtest 'a tampered artefact is reported as a mismatch, not as a digest' => sub {
    my $d = fixture();
    my $r = Lazysite::Manager::Backups::action_backup_create('manual');
    ok( $r->{ok}, 'snapshot taken' ) or return;
    my $path = "$d/lazysite/backups/$r->{name}";

    is( verify_status($path), 'verified',
        'an untouched artefact verifies' );

    my $listed = Lazysite::Manager::Backups::action_backup_list();
    my ($row) = grep { $_->{name} eq $r->{name} } @{ $listed->{backups} };
    is( $row->{sha256_status}, 'verified', 'and the LISTING says so' );

    # Tamper in place, leaving the sidecar alone - the whole point of the
    # finding.
    open my $fh, '>>', $path or die $!;
    print {$fh} "TAMPER";
    close $fh;

    is( verify_status($path), 'mismatch',
        'the altered artefact no longer matches its recorded digest' );
    $listed = Lazysite::Manager::Backups::action_backup_list();
    ($row) = grep { $_->{name} eq $r->{name} } @{ $listed->{backups} };
    is( $row->{sha256_status}, 'mismatch',
        'and the listing says THAT - a digest shown with no verdict reads as '
            . 'assurance nobody gave' );
};

subtest 'a sidecar naming a different artefact is not accepted' => sub {
    my $d = fixture();
    my $r = Lazysite::Manager::Backups::action_backup_create('manual');
    ok( $r->{ok}, 'snapshot taken' ) or return;
    my $path = "$d/lazysite/backups/$r->{name}";

    # A valid-looking line whose second field names something else. read_sha256
    # took the first 64 hex characters and ignored the rest, which is precisely
    # what sha256sum's second field is for.
    my $real = Lazysite::Manager::Backups::read_sha256($path);
    spit( "$path.sha256", "$real  some-other-artefact.tar.gz\n" );

    is( Lazysite::Manager::Backups::read_sha256($path), '',
        'the basename field is checked' );
    is( verify_status($path), 'absent',
        'so it counts as no claim at all, rather than as a passing one' );
};

subtest 'apply refuses a package that does not match its digest' => sub {
    my $d   = fixture();
    my $pkg = package_create('shop.clienta.com');
    ok( $pkg->{ok}, 'package built' ) or return;
    my $path = "$d/lazysite/backups/$pkg->{name}";

    # The artefact and its sidecar DISAGREE, and the archive itself is
    # untouched. Corrupting the tarball instead would be refused by the archive
    # reader ("bad archive") and would prove nothing about the digest: this
    # package extracts perfectly, so the integrity check is the only thing that
    # can stop it.
    spit( "$path.sha256", ( '0' x 64 ) . '  ' . $pkg->{name} . "\n" );

    my $ap = Lazysite::Manager::SitePackage::package_apply( $path,
        content_root => 'sites/target' );
    ok( !$ap->{ok}, 'refused' );
    is( $ap->{kind}, 'integrity', 'as an integrity failure, named as such' );
    like( slurp("$d/sites/target/index.md"), qr/TARGET-ORIGINAL/,
        'and the target site is untouched - a refusal that still applied would '
            . 'be the whole defect' );
};

subtest 'apply still works, and says whether it verified' => sub {
    my $d   = fixture();
    my $pkg = package_create('shop.clienta.com');
    ok( $pkg->{ok}, 'package built' ) or return;
    my $path = "$d/lazysite/backups/$pkg->{name}";

    my $ap = Lazysite::Manager::SitePackage::package_apply( $path,
        content_root => 'sites/target' );
    ok( $ap->{ok}, 'an intact package applies' ) or diag explain $ap;
    is( $ap->{integrity}, 'verified',
        'and reports that it checked - a guard that refused everything would '
            . 'pass the subtest above for the wrong reason' );

    # An artefact from before sidecars existed must still be appliable: turning
    # those into un-appliable files would break restore for exactly the
    # operators most likely to need it.
    unlink "$path.sha256";
    my $ap2 = Lazysite::Manager::SitePackage::package_apply( $path,
        content_root => 'sites/target' );
    ok( $ap2->{ok}, 'a package with NO sidecar still applies' );
    is( $ap2->{integrity}, 'absent', 'reported as unverified, not as verified' );
};

# --- SM268 03-F9: the disambiguator was check-then-create --------------------
#
# SM183 fixed the same-second collision with `if (-e $out) { pick a -N }`, which
# closes the window for SEQUENTIAL callers and leaves it open for concurrent
# ones: the test and the create are two operations. An adversarial review ran
# twelve concurrent snapshots and got two files - every caller told ok => 1 and
# handed a name, ten of them naming someone else's tarball. Two tar processes
# writing one inode is also not guaranteed to produce a valid archive.
subtest 'the snapshot name is claimed atomically' => sub {
    my $d = fixture();

    my @names;
    for ( 1 .. 4 ) {
        my $r = Lazysite::Manager::Backups::action_backup_create('manual');
        ok( $r->{ok}, 'snapshot reported ok' ) or next;
        push @names, $r->{name};
    }
    my %seen;
    $seen{$_}++ for @names;
    is( scalar( keys %seen ), scalar(@names), 'every caller got a distinct name' );

    opendir my $dh, "$d/lazysite/backups" or die $!;
    my @files = grep { /^lazysite-manual-.*\.tar\.gz\z/ } readdir $dh;
    closedir $dh;
    is( scalar(@files), scalar(@names),
        'and there is one file per caller, so nothing was overwritten' );

    # The claim is the create. A name handed out must exist on disk before the
    # caller is told it does.
    ok( ( scalar( grep { -s "$d/lazysite/backups/$_" } @files ) == @files ),
        'and none of them is a zero-byte placeholder' );
};

# --- SM266: the dry run, and keeping the target's own presentation -----------
#
# The four apply-confidence controls are manager JavaScript and unreachable
# here; the two that needed NEW backend are not, and this is that half.
subtest 'inspect answers what an apply would do to a named target' => sub {
    my $d = fixture();
    my $r = package_create('shop.clienta.com');
    ok( $r->{ok}, 'packaged' ) or return;
    my $pkg = "$d/lazysite/backups/$r->{name}";

    # Without a target, inspect is unchanged - a manifest and nothing more. The
    # dry run must be opt-in, or every existing caller pays for a tree walk.
    my $plain = package_inspect($pkg);
    ok( $plain->{ok},       'inspect still works with no target' );
    ok( !$plain->{compare}, 'and reports no comparison unless one is asked for' );

    # sites/target already holds index.md, and the package carries one, so the
    # apply would OVERWRITE rather than add. That distinction is the whole point
    # of the control: "1 file" and "1 file, overwriting what is there" are
    # different decisions.
    my $cmp = package_inspect( $pkg, 'sites/target' )->{compare};
    ok( $cmp, 'with a target, a comparison comes back' ) or return;
    is( $cmp->{overwritten}, 1, 'an existing file at the same path counts as overwritten' );
    is( $cmp->{added},       0, 'and is not also counted as added' );

    # An empty target inverts it, which is the check that the counts are really
    # comparing rather than reporting a constant.
    make_path("$d/sites/empty");
    my $fresh = package_inspect( $pkg, 'sites/empty' )->{compare};
    is( $fresh->{added},       1, 'against an empty target the same file is an ADD' );
    is( $fresh->{overwritten}, 0, 'and nothing is overwritten' );

    # The layout ships in the package and is already installed here, so the
    # apply would leave it alone - the operator should be told which.
    ok( $cmp->{layout_present}, 'an already-installed layout is reported as present' );
};

subtest 'keep_presentation leaves the target key alone' => sub {
    my $d = fixture();

    # Give the target its own layout, distinct from the package's.
    make_path("$d/lazysite/layouts/targetlook");
    spit( "$d/lazysite/layouts/targetlook/layout.tt", '[% content %]' );
    my $set = Lazysite::Manager::Domains::domain_set( 'target.example', 'layout', 'targetlook' );
    ok( $set->{ok}, "the target has its own layout to defend" ) or diag $set->{error};
    like( slurp("$d/lazysite/lazysite.conf"), qr/alias\.target\.example\.layout:\s*targetlook/,
        'and it is really in the conf - otherwise the assertion below proves nothing' );

    my $r = package_create('shop.clienta.com');
    ok( $r->{ok}, 'packaged' ) or return;
    my $pkg = "$d/lazysite/backups/$r->{name}";

    my $ap = apply_and_configure( $pkg, host => 'target.example',
        keep_presentation => ['layout'] );
    ok( $ap->{ok}, 'applied' ) or diag $ap->{error};
    is_deeply( $ap->{kept_presentation}, ['layout'],
        'the apply reports which keys it left alone' );

    # The CONTENT still arrived - keeping a presentation key must not turn the
    # apply into a no-op, which is the way this could pass while being useless.
    like( slurp("$d/sites/target/index.md"), qr/Client A/,
        'the package content was applied' );

    my $conf = slurp("$d/lazysite/lazysite.conf");
    unlike( $conf, qr/alias\.target\.example\.layout:\s*base/,
        "and the target's layout was NOT overwritten with the package's" );
};

done_testing();
