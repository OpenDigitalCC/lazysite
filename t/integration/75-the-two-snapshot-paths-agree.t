#!/usr/bin/perl
# SM484: the two snapshot paths, after the rig named their opposite failures
# on one fixture. The safety snapshot before a RESTORE now scopes to the
# archive's own blast radius (its members' common directory), so a partner
# who can back up can roll back; the site package REPORTS what its staging
# copy could not read instead of shipping an incomplete artefact that says
# ok; and tar's ./-relative member names survive the path scrub.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper                     qw(repo_root);
use Lazysite::Manager::Backups     ();
use Lazysite::Manager::SitePackage ();
use Lazysite::Manager::Domains     ();

plan skip_all => 'running as root: unreadable fixtures are readable'
    if $> == 0;

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
make_path("$d/sites/edge/content");
make_path("$d/primary-only");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nalias_hosts: edge.test\n"
    . "alias.edge.test.content_root: sites/edge\n";
close $cf;
open my $pf, '>', "$d/sites/edge/content/page.md" or die $!;
print {$pf} "---\ntitle: P\n---\nx\n";
close $pf;
$Lazysite::Manager::Backups::DOCROOT      = $d;
$Lazysite::Manager::Backups::LAZYSITE_DIR = "$d/lazysite";
$Lazysite::Manager::SitePackage::DOCROOT  = $d;
$Lazysite::Manager::Domains::DOCROOT      = $d;

my @unchmod;
END { chmod 0755, $_ for @unchmod }

subtest 'A PARTNER WHO CAN BACK UP CAN ROLL BACK' => sub {
    # A good scoped backup of sites/edge; then the PRIMARY tree turns
    # hostile. The old unscoped prerestore snapshot refused on it - the rig's
    # case C - though the restore would never touch that tree.
    my $b = Lazysite::Manager::Backups::action_backup_create( 'manual',
        root => 'sites/edge' );
    ok( $b->{ok}, 'scoped backup created' ) or diag explain $b;
    make_path("$d/primary-only/blocked");
    open my $hf, '>', "$d/primary-only/blocked/x" or die $!;
    print {$hf} "x\n";
    close $hf;
    chmod 0000, "$d/primary-only/blocked";
    push @unchmod, "$d/primary-only/blocked";
    my $r = Lazysite::Manager::Backups::action_backup_restore( $b->{name} );
    ok( $r->{ok}, 'the restore SUCCEEDS - its snapshot covers the blast radius, not the host' )
        or diag explain $r;
};

subtest 'the package SAYS what it does not carry' => sub {
    make_path("$d/sites/edge/content/gated");
    open my $gf, '>', "$d/sites/edge/content/gated/hidden.md" or die $!;
    print {$gf} "x\n";
    close $gf;
    chmod 0000, "$d/sites/edge/content/gated";
    push @unchmod, "$d/sites/edge/content/gated";
    my $pkg = Lazysite::Manager::SitePackage::package_create('edge.test');
    ok( $pkg->{ok}, 'the package still ships' ) or diag explain $pkg;
    ok( ref $pkg->{unreadable} eq 'ARRAY' && @{ $pkg->{unreadable} },
        'and reports the files its copy could not read' )
        or diag explain $pkg;
    unlike( join( '|', @{ $pkg->{unreadable} || [] } ), qr{\A/},
        'as site-relative names, never absolute paths' );
    chmod 0755, "$d/sites/edge/content/gated";
};

subtest 'tar\'s ./-relative names survive the scrub' => sub {
    my $out = Lazysite::Manager::Backups::_scrub_paths(
        "tar: ./primary-only: Cannot open: Permission denied");
    like( $out, qr{\./primary-only}, 'the member name is kept whole' )
        or diag("scrubbed to: $out");
    # Two-segment ./-paths are the OTHER rule's victims (the rig's
    # ./sites/edge/blocked became .<outside>/edge/blocked) - both lookbehind
    # fixes are needed, and each gets its own assertion so a sabotage on
    # either rule bites.
    my $two = Lazysite::Manager::Backups::_scrub_paths(
        "tar: ./sites/edge/blocked: Cannot open: Permission denied");
    like( $two, qr{\./sites/edge/blocked}, 'a two-segment member name is kept whole' )
        or diag("scrubbed to: $two");
    unlike( $out, qr{<outside>}, 'and not mangled into the outside placeholder' );
    # The rule DELIBERATELY keeps an outside path's last two segments (the
    # artefact's name without the host's layout) - so the assertion is that
    # the root is gone, not that every segment is.
    my $abs = Lazysite::Manager::Backups::_scrub_paths(
        "tar: /var/lib/secret/passwd: Cannot open");
    like( $abs, qr{<outside>/secret/passwd}, 'an absolute path keeps only its tail' );
    unlike( $abs, qr{/var/lib}, 'and the host layout is gone' );
};

done_testing();
