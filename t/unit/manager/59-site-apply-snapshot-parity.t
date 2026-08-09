#!/usr/bin/perl
# SM183: applying a site package takes a safety snapshot on EVERY surface.
#
# The control-API apply snapshotted the docroot first, so a bad apply was
# reversible. MCP site_apply and the CLI called the shared apply_and_configure
# directly and did not - and site_apply's own description said so, which made it
# a documented gap rather than a hidden one but did not make it safe. An apply
# overwrites a site's content; reversible on one surface and not on another
# contradicts SM183's whole claim that the artefact, not the tool, is the
# interface.
#
# One more reason it mattered: domain_presentation_set REFUSES to repoint a
# domain's content_root and tells the agent to "use site_apply, which takes a
# snapshot first". The codebase was already asserting the property it did not
# have.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::SitePackage qw(package_create apply_and_configure);

sub spit { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh }

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
    spit( "$d/sites/target/index.md",           "# The target's OWN page\n" );
    spit( "$d/lazysite/layouts/base/layout.tt", '[% content %]' );
    $Lazysite::Manager::SitePackage::DOCROOT   = $d;
    $Lazysite::Manager::SitePackage::auth_user = 'tester';
    return $d;
}

sub snapshots {
    my ($d) = @_;
    opendir my $dh, "$d/lazysite/backups" or return ();
    my @s = grep { /^lazysite-prerestore-/ } readdir $dh;
    closedir $dh;
    return @s;
}

# --- the shared path snapshots, which is what MCP and the CLI call ----------
subtest 'apply_and_configure takes a safety snapshot by default' => sub {
    my $d = fixture();
    my $r = package_create('shop.clienta.com');
    ok( $r->{ok}, 'packaged the source site' ) or diag $r->{error};

    is( scalar snapshots($d), 0, 'no snapshot before the apply' );

    my $ap = apply_and_configure( "$d/lazysite/backups/$r->{name}",
        host => 'target.example' );
    ok( $ap->{ok}, 'apply succeeded' ) or diag( $ap->{error} // '' );

    cmp_ok( scalar snapshots($d), '>=', 1,
        'a prerestore snapshot exists - this is the rollback point MCP and the '
            . 'CLI did not have' );
    ok( defined $ap->{safety} && length $ap->{safety},
        'and its name is RETURNED, so a caller can tell the operator what to '
            . 'restore without going looking' );
};

# --- a caller that already snapshotted is not made to do it twice -----------
# The control API takes its snapshot before its own scope checks, so it passes
# snapshot => 0. That is for a caller that has already taken one; it is not an
# opt-out for convenience, and nothing in the tree should pass it otherwise.
subtest 'snapshot => 0 suppresses it for a caller that already has one' => sub {
    my $d = fixture();
    my $r = package_create('shop.clienta.com');
    ok( $r->{ok}, 'packaged' ) or diag $r->{error};

    my $ap = apply_and_configure( "$d/lazysite/backups/$r->{name}",
        host => 'target.example', snapshot => 0 );
    ok( $ap->{ok}, 'apply succeeded' ) or diag( $ap->{error} // '' );
    is( scalar snapshots($d), 0, 'no second snapshot was taken' );
    ok( !defined $ap->{safety}, 'and no safety name is claimed' );
};

# --- the snapshot actually captures the pre-apply content -------------------
# A snapshot that exists but does not contain the overwritten page would be
# worse than none: it would look like a rollback point and not be one.
subtest 'the snapshot contains the content the apply overwrote' => sub {
    my $d  = fixture();
    my $r  = package_create('shop.clienta.com');
    my $ap = apply_and_configure( "$d/lazysite/backups/$r->{name}",
        host => 'target.example', clean => 1 );
    ok( $ap->{ok}, 'apply succeeded' ) or diag( $ap->{error} // '' );

    my $snap = "$d/lazysite/backups/" . $ap->{safety};
    ok( -f $snap, 'the named snapshot is on disk' );

    my @in = `tar tzf \Q$snap\E 2>/dev/null`;
    chomp @in;
    ok( ( grep { m{sites/target/index\.md$} } @in ),
        "the target's own page is inside it - the apply replaced that file, so "
            . 'this is what a rollback needs' );
};

# --- the surfaces agree ------------------------------------------------------
subtest 'every surface reaches the snapshotting path' => sub {
    my $root = "$FindBin::Bin/../../..";
    my %src;
    for my $f (qw(lazysite-mcp.pl tools/lazysite-site.pl lazysite-manager-api.pl)) {
        open my $fh, '<', "$root/$f" or die "$f: $!";
        local $/;
        $src{$f} = <$fh>;
        close $fh;
    }

    # MCP and the CLI must NOT pass snapshot => 0 - they have no snapshot of
    # their own, so opting out would restore the exact gap this closes.
    unlike( $src{'lazysite-mcp.pl'}, qr/snapshot\s*=>\s*0/,
        'MCP does not opt out of the snapshot' );
    unlike( $src{'tools/lazysite-site.pl'}, qr/snapshot\s*=>\s*0/,
        'the CLI does not opt out either' );

    # The control API may, because it takes its own first.
    like( $src{'lazysite-manager-api.pl'}, qr/snapshot\s*=>\s*0/,
        'the control API opts out, having already snapshotted' );
    like( $src{'lazysite-manager-api.pl'}, qr/action_backup_create\('prerestore'\)/,
        'and that is what it took' );

    # The description must no longer tell an agent the opposite.
    unlike( $src{'lazysite-mcp.pl'}, qr/A safety snapshot is NOT taken here/,
        'site_apply no longer documents the gap it used to have' );
};

done_testing();
