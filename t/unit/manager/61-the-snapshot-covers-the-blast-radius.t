#!/usr/bin/perl
# SM412: the apply's safety snapshot scopes to the target, not the docroot.
#
# Diagnosed in the field by the partner agent it blocked, on a multi-domain
# instance: site_apply to edge2 (content_root sites/edge2) refused with
# "safety snapshot failed - tar exited 2 ... Cannot open: Permission denied"
# on the PRIMARY domain's tree - a tree the account could not read, and the
# apply would never touch. site_backup of the same domain, same host, same
# account, succeeded 26 seconds later, because IT scopes and the snapshot did
# not. The snapshot's job is to cover the blast radius of the operation it
# guards; package_apply writes only under the target content_root.
#
# DRIVEN, NOT READ: the multi-domain instance is a real fixture and the
# unreadable primary tree is a real chmod-000 directory. The old behaviour is
# reproduced (unscoped snapshot fails against it), the new behaviour is
# proved (scoped snapshot succeeds, carries exactly the target subtree, and
# restores), and the apply that the field refusal blocked completes.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::SitePackage qw(package_create apply_and_configure);
use Lazysite::Manager::Backups     ();
use Lazysite::Manager::Domains     ();

plan skip_all => 'chmod 000 does not bar root' if $> == 0;

sub spit { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh }

my @locked;    # chmod-000 dirs to unlock before CLEANUP can remove them
END { chmod 0755, $_ for @locked }

sub fixture {
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/lazysite/layouts/base", "$d/sites/clienta", "$d/sites/target",
        "$d/private-area" );
    spit(
        "$d/lazysite/lazysite.conf",
        "site_name: Agency\n"
            . "alias_hosts: shop.clienta.com, target.example\n"
            . "alias.shop.clienta.com.content_root: sites/clienta\n"
            . "alias.shop.clienta.com.layout: base\n"
            . "alias.target.example.content_root: sites/target\n"
    );
    spit( "$d/index.md",                        "# PRIMARY HOME\n" );
    spit( "$d/sites/clienta/index.md",          "# Client A\n" );
    spit( "$d/sites/target/index.md",           "# TARGET-ORIGINAL\n" );
    spit( "$d/private-area/secret.md",          "# not for this account\n" );
    spit( "$d/lazysite/layouts/base/layout.tt", '[% content %]' );

    # The field condition: a directory in the PRIMARY tree the calling account
    # cannot read. On the real instance it was the primary domain's web dir.
    chmod 0000, "$d/private-area" or die $!;
    push @locked, "$d/private-area";

    $Lazysite::Manager::SitePackage::DOCROOT   = $d;
    $Lazysite::Manager::SitePackage::auth_user = 'tester';
    $Lazysite::Manager::Backups::DOCROOT       = $d;
    $Lazysite::Manager::Backups::LAZYSITE_DIR  = "$d/lazysite";
    $Lazysite::Manager::Backups::auth_user     = 'tester';
    $Lazysite::Manager::Domains::DOCROOT       = $d;
    return $d;
}

sub members {
    my ($archive) = @_;
    my @m = `tar tzf \Q$archive\E 2>/dev/null`;
    chomp @m;
    return @m;
}

# --- the field failure, reproduced ------------------------------------------
subtest 'an unscoped snapshot fails against the unreadable primary tree' => sub {
    my $d = fixture();
    my $r = Lazysite::Manager::Backups::action_backup_create('prerestore');
    ok( !$r->{ok}, 'refused - which is the field failure this fixes' )
        or diag explain $r;
    like( $r->{detail} // '', qr/Permission denied|Cannot open/i,
        'and for the reason the field saw' );
};

# --- the scoped snapshot ------------------------------------------------------
subtest 'a scoped snapshot succeeds and carries exactly the target subtree' => sub {
    my $d = fixture();
    my $r = Lazysite::Manager::Backups::action_backup_create( 'prerestore',
        root => 'sites/target' );
    ok( $r->{ok}, 'succeeds despite the unreadable tree it no longer touches' )
        or diag explain $r;

    my @m = grep { $_ ne './' } members("$d/lazysite/backups/$r->{name}");
    ok( @m > 0, 'the archive has members' );
    my @outside = grep { !m{^\./sites/target(?:/|$)} } @m;
    is( scalar @outside, 0, 'every member is inside the target subtree' )
        or diag join "\n", @outside;

    ok( -f "$d/lazysite/backups/$r->{name}.sha256", 'it carries its digest sidecar' );

    # And it RESTORES: overwrite the target, extract, the original returns.
    spit( "$d/sites/target/index.md", "# CLOBBERED\n" );
    system( 'tar', 'xzf', "$d/lazysite/backups/$r->{name}", '-C', $d ) == 0
        or die 'extract failed';
    open my $fh, '<', "$d/sites/target/index.md" or die $!;
    like( scalar <$fh>, qr/TARGET-ORIGINAL/, 'the snapshot restores the target' );
};

# --- scope validation ---------------------------------------------------------
subtest 'the scope is validated like any other path input' => sub {
    my $d = fixture();

    # THE CASE THAT MATTERS: traversal to a directory that EXISTS. A dropped
    # validation still refuses '../nonexistent' - tar fails - so asserting
    # bare refusal proves nothing. Traversal to an existing sibling would
    # SUCCEED without validation and archive content from outside the docroot
    # into a self-service-downloadable backup. The first version of this
    # subtest missed that: a sabotage that deleted the validation passed it.
    make_path("$d-outside");
    spit( "$d-outside/loot.md", "# outside the docroot\n" );
    my $base = ( split m{/}, $d )[-1];
    my $trav = Lazysite::Manager::Backups::action_backup_create( 'prerestore',
        root => "../$base-outside" );
    ok( !$trav->{ok}, 'traversal to an EXISTING outside directory is refused' );
    like( $trav->{reason} // '', qr/invalid scope/,
        'by the validation, not by tar happening to fail' );
    remove_tree("$d-outside");

    my $abs = Lazysite::Manager::Backups::action_backup_create( 'prerestore',
        root => '/etc' );
    ok( !$abs->{ok}, 'an absolute scope is refused' );

    # A scope that does not exist yet is a NO-OP, not a refusal: the first
    # apply into a freshly configured domain creates its content root, and
    # there is nothing a snapshot could protect. The suite caught the refusal
    # breaking exactly that (t/unit/manager/35's first-time apply).
    my $new = Lazysite::Manager::Backups::action_backup_create( 'prerestore',
        root => 'sites/does-not-exist' );
    ok( $new->{ok}, 'a not-yet-existing scope is an honest no-op' );
    is( $new->{name}   // '', '', 'with no archive name' );
    like( $new->{note} // '', qr/does not exist yet/, 'and it says why' );

    # But an existing NON-DIRECTORY is a broken state and stays refused.
    spit( "$d/sites/oddfile", "not a dir\n" );
    my $odd = Lazysite::Manager::Backups::action_backup_create( 'prerestore',
        root => 'sites/oddfile' );
    ok( !$odd->{ok}, 'a scope that exists as a file is refused' );
    my $r = Lazysite::Manager::Backups::action_backup_create( 'full',
        root => 'sites/target' );
    ok( !$r->{ok}, 'a full backup cannot be scoped - it is whole-site by definition' );
    like( $r->{reason} // '', qr/cannot be scoped/, 'and says so' );
};

# --- the apply the field refusal blocked --------------------------------------
subtest 'site-package apply to a content-rooted domain now completes' => sub {
    my $d   = fixture();
    my $pkg = package_create('shop.clienta.com');
    ok( $pkg->{ok}, 'packaged the source domain' ) or diag $pkg->{error};

    my $r = apply_and_configure( "$d/lazysite/backups/$pkg->{name}",
        host => 'target.example', clean => 1 );
    ok( $r->{ok}, 'the apply that used to refuse with snapshot-failed succeeds' )
        or diag explain $r;

    open my $fh, '<', "$d/sites/target/index.md" or die $!;
    like( scalar <$fh>, qr/Client A/, 'and the content arrived' );

    # The snapshot it took is scoped: no member outside the target.
    my ($safety) = grep { /prerestore/ } do {
        opendir my $dh, "$d/lazysite/backups" or die $!;
        grep { !/\.sha256$|\.err$/ } readdir $dh;
    };
    ok( $safety, 'a safety snapshot was taken' );
    my @outside = grep { $_ ne './' && !m{^\./sites/target(?:/|$)} }
        members("$d/lazysite/backups/$safety");
    is( scalar @outside, 0, 'and it is scoped to the target' )
        or diag join "\n", @outside;
};

# --- the primary keeps the wide snapshot ---------------------------------------
subtest 'an unscoped call still snapshots the whole content tree' => sub {
    my $d = fixture();
    chmod 0755, "$d/private-area";    # readable again: this case is about scope
    my $r = Lazysite::Manager::Backups::action_backup_create('prerestore');
    ok( $r->{ok}, 'succeeds when everything is readable' ) or diag explain $r;
    my @m = members("$d/lazysite/backups/$r->{name}");
    ok( ( grep { m{^\./index\.md$} } @m ),        'carries the primary content' );
    ok( ( grep { m{^\./sites/target/} } @m ),     'and the domain subtrees' );
    ok( !( grep { m{^\./lazysite/backups} } @m ), 'and still not the backups dir' );
};

done_testing();
