#!/usr/bin/perl
# SM874: the apply's safety snapshot covers the TARGET, and undoing an apply
# actually puts the target back.
#
# Found by the site agent walking 1315S-03 (tier A, A3) on edge: after a fully
# confirmed undo the target domain still held the applied package, and its
# content root held the PRIMARY's files. Two defects behind it, both reproduced
# in tmp/repro-sm874-apply-undo.pl before either was fixed:
#
#   1. The safety snapshot was UNSCOPED. SM412 added `root` to
#      action_backup_create for exactly this - its comment says the apply's
#      snapshot "used to tar the whole docroot whatever the target" - and fixed
#      it inside apply_and_configure. But lazysite-manager-api.pl passes
#      `snapshot => 0` to opt OUT of that shared path and took its own, with no
#      root. So the surface a person clicks kept the defect SM412 removed.
#
#   2. A restore is an OVERLAY. It writes the archive over the site and removes
#      nothing, so an apply that ADDS files cannot be undone by one - while the
#      undo bar promised "puts the site back as it was immediately before the
#      apply". The field apply added 241 files.
#
# WHY THIS FILE EXISTS AND t/unit/manager/61 DID NOT CATCH IT. 61 drives the
# LIBRARY (apply_and_configure), where the scoped snapshot works and always
# did. t/unit/manager/59 checked the control API - by matching
# `action_backup_create('prerestore')` in the SOURCE, which proved the call
# existed and never what it covered. A regex over a caller is not a test of the
# caller. So this drives the behaviour: build a package, apply it to a second
# domain, undo, and look at the target.
#
# WHAT THIS FILE DOES NOT COVER, said plainly so the next reader does not assume
# it does. lazysite-manager-api.pl is a CGI and cannot be loaded in-process, so
# `apply_to_target` below REPLICATES its call sequence rather than invoking it -
# which means it passes `root` itself. Reverting the fix in the control API does
# NOT fail this file; it fails t/unit/manager/59, whose source check is what
# pins the surface to the behaviour proved here. The two are a pair and neither
# is sufficient on its own: 59 says the surface asks for the right thing, 62
# says the right thing then happens. Both were verified by reverting both fixes
# and watching each fail - tmp/prove-sm874-gates-fail.sh.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Manager::SitePackage qw(package_create apply_and_configure);
use Lazysite::Manager::Backups ();
use Lazysite::Manager::Domains ();

sub spit { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh }

sub slurp {
    open my $fh, '<', $_[0] or return '(absent)';
    local $/;
    my $x = <$fh>;
    return $x;
}

sub entries {
    my ($dir) = @_;
    opendir my $dh, $dir or return '(no such dir)';
    my @e = sort grep { !/\A\.\.?\z/ } readdir $dh;
    closedir $dh;
    return join ' ', @e;
}

# A multi-domain instance: a primary with its own pages, a SOURCE domain to
# package, and a TARGET domain to apply it to. The primary's pages matter -
# they are what an unscoped snapshot wrongly sweeps up.
sub fixture {
    # site_tempdir, not a bare tempdir: the engine gets a docroot a level down,
    # so a code path that resolves the docroot's PARENT - the private store does
    # exactly that - lands inside the fixture rather than in the tempdir root
    # (t/lint/118 holds the line, and caught this file).
    my $d = site_tempdir();
    make_path( "$d/lazysite/layouts/base", "$d/lazysite/backups",
        "$d/sites/source", "$d/sites/target" );
    spit(
        "$d/lazysite/lazysite.conf",
        "site_name: Primary\n"
            . "alias_hosts: target.example, source.example\n"
            . "alias.target.example.content_root: sites/target\n"
            . "alias.source.example.content_root: sites/source\n"
    );
    spit( "$d/index.md",                        "# PRIMARY HOME\n" );
    spit( "$d/gallery.md",                      "# primary gallery\n" );
    spit( "$d/sites/source/index.md",           "# SOURCE-PACKAGE-CONTENT\n" );
    spit( "$d/sites/source/about.md",           "# source about\n" );
    spit( "$d/sites/target/index.md",           "# TARGET-ORIGINAL\n" );
    spit( "$d/sites/target/contact.md",         "# target contact\n" );
    spit( "$d/lazysite/layouts/base/layout.tt", '[% content %]' );

    $Lazysite::Manager::SitePackage::DOCROOT   = $d;
    $Lazysite::Manager::SitePackage::auth_user = 'tester';
    $Lazysite::Manager::Backups::DOCROOT       = $d;
    $Lazysite::Manager::Backups::LAZYSITE_DIR  = "$d/lazysite";
    $Lazysite::Manager::Backups::auth_user     = 'tester';
    $Lazysite::Manager::Domains::DOCROOT       = $d;
    return $d;
}

# The control API's sequence, in its order: snapshot the target, then apply
# with the shared layer's own snapshot switched off.
sub apply_to_target {
    my ( $d, %o ) = @_;
    my $pk = package_create('source.example');
    die 'package_create: ' . ( $pk->{error} // '?' ) unless $pk->{ok};
    my $safety = Lazysite::Manager::Backups::action_backup_create( 'prerestore',
        ( $o{scoped} ? ( root => 'sites/target' ) : () ) );
    die 'snapshot: ' . ( $safety->{error} // '?' ) unless $safety->{ok};
    my $ap = apply_and_configure( "$d/lazysite/backups/" . ( $pk->{name} // $pk->{file} ),
        host => 'target.example', content_root => 'sites/target', snapshot => 0 );
    die 'apply: ' . ( $ap->{error} // '?' ) unless $ap->{ok};
    return $safety->{file} // $safety->{name};
}

subtest "the apply's safety snapshot carries the target, not the primary" => sub {
    my $d    = fixture();
    my $snap = apply_to_target( $d, scoped => 1 );
    my @m    = `tar tzf \Q$d/lazysite/backups/$snap\E 2>/dev/null`;
    chomp @m;

    ok( ( grep { m{sites/target/index\.md$} } @m ),
        "the target's own page is in the snapshot - that is what a rollback needs" );
    ok( !( grep { m{(?:^|/)gallery\.md$} } @m ),
        "the PRIMARY's pages are NOT" )
        or diag( "The snapshot swept up the primary's tree. That is SM412's "
            . "defect, alive on the control API because it opts out of the "
            . "shared snapshot and took an unscoped one of its own.\n  members: "
            . join( ', ', @m ) );
};

subtest 'an overlay restore cannot undo an apply - which is why replace exists' => sub {
    my $d    = fixture();
    my $snap = apply_to_target( $d, scoped => 1 );
    is( slurp("$d/sites/target/index.md"), "# SOURCE-PACKAGE-CONTENT\n",
        'the apply landed' );

    my $r = Lazysite::Manager::Backups::action_backup_restore($snap);
    ok( $r->{ok}, 'the overlay restore succeeds' );
    is( slurp("$d/sites/target/index.md"), "# TARGET-ORIGINAL\n",
        'a CHANGED file is reverted' );
    ok( -f "$d/sites/target/about.md",
        'but a file the package ADDED is still there - the overlay removes nothing' )
        or diag( 'If this now fails, the restore has become destructive by '
            . 'default, which is not what SM874 did: replace is opt-in.' );
};

subtest 'replace puts the target back exactly' => sub {
    my $d    = fixture();
    my $snap = apply_to_target( $d, scoped => 1 );

    my $r = Lazysite::Manager::Backups::action_backup_restore( $snap, replace => 1 );
    ok( $r->{ok}, 'the replace restore succeeds' ) or diag( $r->{error} // '' );
    is( slurp("$d/sites/target/index.md"), "# TARGET-ORIGINAL\n",
        'the changed file is back' );
    is( entries("$d/sites/target"), 'contact.md index.md',
        'and the added file is GONE - the target is as it was before the apply' )
        or diag( 'This is the clause 1315S-03 failed on: undo confirmed, target '
            . 'unchanged.' );

    # The blast radius is the target and nothing else.
    is( slurp("$d/index.md"), "# PRIMARY HOME\n",
        "the primary is untouched by the target's undo" );
    ok( -f "$d/sites/source/index.md", 'and so is the source domain' );
};

subtest 'replace REFUSES when the archive covers no single folder' => sub {
    my $d = fixture();

    # An unscoped snapshot spans the whole docroot, so "clear it first" would
    # mean clearing the docroot. That is the one case this must never guess.
    my $snap = apply_to_target( $d, scoped => 0 );
    my $r = Lazysite::Manager::Backups::action_backup_restore( $snap, replace => 1 );

    ok( !$r->{ok}, 'refused' );
    like( $r->{error}, qr/covers no single folder/, 'and says why' );
    is( slurp("$d/index.md"), "# PRIMARY HOME\n",
        'the primary still stands - nothing was cleared' );
    ok( -f "$d/sites/target/about.md",
        'and the target was not touched either - a refusal writes nothing' );
};

done_testing();
