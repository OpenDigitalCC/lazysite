#!/usr/bin/perl
# SM559: the report a package carries about what it omitted must name the
# right thing. @COPY_FAILED was one file-scoped list fed by every walker, so
# an unreadable LAYOUT directory came back as unreadable site content under a
# layout-relative path, and package_apply's copy failures - never drained -
# surfaced in the next package_create of a long-lived process. Found by the
# backups structural review (N4), proven by probe
# tmp/bp-probe-copy-failed-layout.t. The walkers now return their failures
# and the caller labels them with the tree they came from.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::SitePackage qw(package_create package_apply);

plan skip_all => 'running as root: unreadable fixtures are readable' if $> == 0;

sub spit { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh }

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/layouts/base/themes/blue/assets", "$d/sites/a", "$d/sites/t" );
spit( "$d/lazysite/lazysite.conf",
    "site_name: Agency\nalias_hosts: a.example\n"
        . "alias.a.example.content_root: sites/a\n"
        . "alias.a.example.layout: base\nalias.a.example.theme: blue\n" );
spit( "$d/sites/a/index.md",                                   "# A\n" );
spit( "$d/lazysite/layouts/base/layout.tt",                    '[% content %]' );
spit( "$d/lazysite/layouts/base/themes/blue/theme.json",       '{}' );
spit( "$d/lazysite/layouts/base/themes/blue/assets/style.css", 'x' );
$Lazysite::Manager::SitePackage::DOCROOT = $d;
my $bk = "$d/lazysite/backups";

my @restore;
END { chmod 0755, $_ for @restore }

subtest 'an unreadable layout directory is reported as LAYOUT, under its own tree' => sub {
    my $assets = "$d/lazysite/layouts/base/themes/blue/assets";
    chmod 0000, $assets;
    push @restore, $assets;
    my $r = package_create('a.example');
    chmod 0755, $assets;
    is( $r->{ok}, 1, 'package_create ok' ) or diag explain $r;
    ok( !$r->{unreadable}, 'no site CONTENT is reported unreadable' )
        or diag explain $r->{unreadable};
    is( $r->{manifest}{unreadable_omitted}, 0, 'and the content count in the manifest is 0' );
    is_deeply( $r->{unreadable_layout}, ['lazysite/layouts/base/themes/blue/assets/'],
        'the layout directory is reported under the layout tree it came from' )
        or diag explain $r->{unreadable_layout};
    is( $r->{manifest}{layout_unreadable_omitted}, 1,
        'the manifest carries a layout count - a count, never a path' );
    unlike( join( '|', @{ $r->{unreadable_layout} || [] } ), qr{\A/},
        'and no absolute path leaves the walker' );
};

subtest 'an apply reports what it could not copy, and the next create is clean' => sub {
    my $made = package_create('a.example');
    is( $made->{ok}, 1, 'a clean package to apply' ) or diag explain $made;
    my $target = "$d/sites/t";
    chmod 0555, $target;
    push @restore, $target;
    my $ap = package_apply( "$bk/$made->{name}", content_root => 'sites/t' );
    chmod 0755, $target;
    is( ref $ap, 'HASH', 'apply returned' ) or diag $@;
    is_deeply( $ap->{copy_failed}, ['content/index.md'],
        'the apply names the file it could not write, labelled by tree' )
        or diag explain $ap;
    my $again = package_create('a.example');
    is( $again->{ok}, 1, 'a later create in the same process ok' );
    ok( !$again->{unreadable} && !$again->{unreadable_layout},
        "and it reports nothing - the apply's failures did not leak into it" )
        or diag explain [ $again->{unreadable}, $again->{unreadable_layout} ];
    is( $again->{manifest}{unreadable_omitted}, 0, 'manifest count 0' );
};

done_testing;
