#!/usr/bin/perl
# DP-6 / SM410 finding B: a site package can carry a table's data, opt-in.
#
# THE DEFECT THIS CLOSES. Content backups exclude ./lazysite entirely and a site
# package copies content, nav and layout only - so before this a migrated or
# content-restored site arrived WITHOUT its database and nothing said so. The
# spec had called backup participation a nice-to-have; the audit corrected that
# to a requirement, because silent data loss on the operation an operator runs
# when something has already gone wrong is the worst shape there is.
#
# OPT-IN, AND THE TABLES ARE NAMED. Opt-in is the release manager's call: a
# package is a portable hand-over artefact, so shipping table contents by
# default hands a third party whatever an operator put in a directory or a
# contact table.
#
# NAMED rather than a boolean came out of building it. The data store is
# INSTANCE-WIDE - one lazysite/db/data.sqlite for the whole install - so "this
# domain's data" does not exist, and a flag would have swept every table on the
# instance, another domain's included, into the one artefact that travels
# between organisations.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../../../lib";

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}

use Lazysite::Data::Tables qw(apply_schema insert_row read_rows export_all_rows);
use Lazysite::Data::Descriptor qw(load_descriptor);
use Lazysite::Data::Export qw(export_table import_table);
use Lazysite::Manager::SitePackage ();
use Lazysite::Manager::Domains     ();

sub site {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/db/tables");
    open my $fh, '>', "$d/lazysite/db/tables/products.yaml" or die $!;
    print {$fh} "title: Products\nkey: code\nfields:\n  code:\n    type: text\n"
        . "    required: true\n  name:\n    type: text\n"
        . "  price:\n    type: decimal\n    digits: 8\n    places: 2\n";
    close $fh;
    return $d;
}

subtest 'export_all_rows pages past the read cap' => sub {
    # read_rows caps at 1000 and that cap STAYS - an unbounded select against a
    # table an agent has been filling is how a page renders for a minute. An
    # export is the one caller that wants everything, so it pages.
    my $d = site();
    apply_schema( $d, 'products' );
    insert_row( $d, 'products', { code => sprintf( 'P%04d', $_ ), name => "n$_" } )
        for 1 .. 1200;

    my $capped = read_rows( $d, 'products' );
    is( scalar @{ $capped->{rows} }, 200, 'an ordinary read is capped' );

    my $all = export_all_rows( $d, 'products' );
    ok( $all->{ok}, 'the export succeeds' ) or diag( $all->{error} );
    is( scalar @{ $all->{rows} }, 1200, 'and returns every row' )
        or diag( 'A paged export that loses rows is worse than one that '
            . 'refuses: the package looks complete.' );

    # Ordered by key, so the batches cannot overlap or skip. Without an ORDER
    # BY, SQLite may return rows in a different order between queries and a
    # paged read silently drops some.
    my %seen;
    $seen{ $_->{code} }++ for @{ $all->{rows} };
    is( scalar keys %seen, 1200, 'with no duplicates and no gaps' );
};

subtest 'the round trip an apply performs' => sub {
    my $src = site();
    apply_schema( $src, 'products' );
    insert_row( $src, 'products',
        { code => 'W1', name => q{Bob's "widget"}, price => '120.00' } );
    insert_row( $src, 'products', { code => 'A1', name => 'Anvil', price => '9.99' } );

    my $d    = load_descriptor( 'products', {
            key    => 'code',
            fields => {
                code  => { type => 'text', required => 1 },
                name  => { type => 'text' },
                price => { type => 'decimal', digits => 8, places => 2 },
            } } );
    my $rows = export_all_rows( $src, 'products' );
    my $json = JSON::PP->new->canonical->encode( export_table( $d, $rows->{rows} ) );

    # A FRESH instance, as an apply builds one.
    my $dst = site();
    apply_schema( $dst, 'products' );
    my $imp = import_table( $d, JSON::PP->new->decode($json) );
    ok( $imp->{ok}, 'the export imports on the far side' ) or diag( $imp->{error} );
    insert_row( $dst, 'products', $_ ) for @{ $imp->{rows} };

    my $got = read_rows( $dst, 'products', order_by => 'code' )->{rows};
    is( scalar @{$got}, 2, 'both rows arrive' );
    is( $got->[1]{name}, q{Bob's "widget"}, 'the awkward text survives' );
    is( $got->[0]{price}, '9.99',   'and the prices' );
    is( $got->[1]{price}, '120.00', 'trailing zeros included' )
        or diag( 'The decimal is a STRING in the export for exactly this - a '
            . 'restore is when a lost decimal place is least likely to be '
            . 'questioned.' );
};

subtest 'an apply REFUSES a table that already holds rows' => sub {
    # Applying a package onto an instance already in use is the dangerous case:
    # restoring over a populated table replaces a live product list with a
    # snapshot from whenever the package was built, and the operator asked for
    # a site, not for that.
    my $dst = site();
    apply_schema( $dst, 'products' );
    insert_row( $dst, 'products', { code => 'LIVE', name => 'in use' } );

    my $existing = read_rows( $dst, 'products', limit => 1 );
    ok( scalar @{ $existing->{rows} },
        'the occupancy check sees the live row' )
        or diag( 'This is the check package_apply makes before restoring; if '
            . 'it cannot see a row, it would overwrite one.' );
};

subtest 'a shape that no longer matches is refused, not coerced' => sub {
    my $src = site();
    apply_schema( $src, 'products' );
    insert_row( $src, 'products', { code => 'W1', price => '1.00' } );
    my $d = load_descriptor( 'products', {
            key => 'code',
            fields => { code => { type => 'text', required => 1 },
                name => { type => 'text' },
                price => { type => 'decimal', digits => 8, places => 2 } } } );
    my $export = export_table( $d, export_all_rows( $src, 'products' )->{rows} );

    my $changed = load_descriptor( 'products', {
            key => 'code',
            fields => { code => { type => 'text', required => 1 },
                name => { type => 'text' },
                price => { type => 'text' } } } );
    my $r = import_table( $changed, $export );
    ok( !$r->{ok}, 'a package built against a different shape is refused' )
        or diag( 'Coercing across a shape change during a RESTORE is a '
            . 'migration performed silently, at the moment something has '
            . 'already gone wrong.' );
};

subtest 'THE PACKAGE ITSELF - built and applied, not just its parts' => sub {
    # THE FIRST VERSION OF THIS FILE NEVER CALLED package_create OR
    # package_apply. It exercised export_all_rows and import_table and called
    # that DP-6, and the sabotage matrix said so: removing the "a failed export
    # fails the package" guard and removing the apply's occupancy check both
    # passed, because nothing here reached either.
    #
    # That is the SM470 lesson repeating within a day - a test that covers the
    # pieces and not the entry point. So this drives the real thing.
    my $base = tempdir( CLEANUP => 1 );
    my $d    = "$base/public_html";
    make_path( "$d/lazysite/backups", "$d/lazysite/db/tables" );
    open my $cf, '>', "$d/lazysite.conf" or die $!;
    print {$cf} "site_name: t\n";
    close $cf;
    open my $dc, '>', "$d/lazysite/domains.conf" or die $!;
    print {$dc} '';
    close $dc;
    open my $pg, '>', "$d/index.md" or die $!;
    print {$pg} "---\ntitle: Home\n---\nHome\n";
    close $pg;
    open my $df, '>', "$d/lazysite/db/tables/products.yaml" or die $!;
    print {$df} "title: Products\nkey: code\nfields:\n  code:\n    type: text\n"
        . "    required: true\n  price:\n    type: decimal\n    digits: 8\n"
        . "    places: 2\n";
    close $df;

    local $Lazysite::Manager::SitePackage::DOCROOT   = $d;
    local $Lazysite::Manager::SitePackage::auth_user = 'alice';
    local $Lazysite::Manager::Domains::DOCROOT       = $d;

    apply_schema( $d, 'products' );
    insert_row( $d, 'products', { code => 'W1', price => '120.00' } );

    # WITHOUT the opt-in: no data, and the manifest SAYS the table was left.
    my $plain = Lazysite::Manager::SitePackage::package_create('(default)');
    ok( $plain->{ok}, 'a package builds without data' ) or do {
        diag( $plain->{error} // '' );
        return;
    };
    is( $plain->{manifest}{data_omitted}, 1,
        'and the manifest reports the table it did NOT carry' )
        or diag( 'The omission is correct and completely silent, so the '
            . 'receiving operator would have no way to learn this instance '
            . 'has tables at all - the same reasoning as SM286 private '
            . 'content.' );
    is_deeply( $plain->{manifest}{data}, [], 'carrying nothing' );

    # WITH the opt-in, naming the table.
    my $withdata = Lazysite::Manager::SitePackage::package_create( '(default)',
        data_tables => ['products'] );
    ok( $withdata->{ok}, 'a package builds WITH the named table' )
        or diag( $withdata->{error} // '' );
    is( $withdata->{manifest}{data}[0]{table}, 'products', 'the table is named' );
    is( $withdata->{manifest}{data}[0]{rows}, 1, 'with its row count' );
    is( $withdata->{manifest}{data_omitted}, 0, 'and nothing is left behind' );

    # A NAMED TABLE THAT CANNOT BE EXPORTED FAILS THE PACKAGE.
    my $bad = Lazysite::Manager::SitePackage::package_create( '(default)',
        data_tables => [ 'products', 'nosuchtable' ] );
    ok( !$bad->{ok}, 'naming a table that does not exist fails the build' )
        or diag( 'An operator who asked for two tables and silently got one '
            . 'would hand over a package they believe is complete.' );
    like( $bad->{error}, qr/nosuchtable/, 'naming which' );
};

subtest 'APPLY: the data arrives on a fresh instance, and is refused on a busy one'
    => sub {
    # The other half, driven for real. Asserting the occupancy CHECK works is
    # not asserting package_apply uses it - the same distinction that cost a
    # round earlier in this file.
    my $base = tempdir( CLEANUP => 1 );
    my $src  = "$base/src";
    make_path( "$src/lazysite/backups", "$src/lazysite/db/tables" );
    for my $pair ( [ "$src/lazysite.conf", "site_name: t\n" ],
        [ "$src/lazysite/domains.conf", '' ],
        [ "$src/index.md",              "---\ntitle: Home\n---\nHome\n" ] )
    {
        open my $fh, '>', $pair->[0] or die $!;
        print {$fh} $pair->[1];
        close $fh;
    }
    open my $df, '>', "$src/lazysite/db/tables/products.yaml" or die $!;
    my $desc = "title: Products\nkey: code\nfields:\n  code:\n    type: text\n"
        . "    required: true\n  price:\n    type: decimal\n    digits: 8\n"
        . "    places: 2\n";
    print {$df} $desc;
    close $df;

    local $Lazysite::Manager::SitePackage::DOCROOT   = $src;
    local $Lazysite::Manager::SitePackage::auth_user = 'alice';
    local $Lazysite::Manager::Domains::DOCROOT       = $src;

    apply_schema( $src, 'products' );
    insert_row( $src, 'products', { code => 'W1', price => '120.00' } );
    insert_row( $src, 'products', { code => 'A1', price => '9.99' } );

    my $built = Lazysite::Manager::SitePackage::package_create( '(default)',
        data_tables => ['products'] );
    ok( $built->{ok}, 'the package builds' ) or do {
        diag( $built->{error} // '' );
        return;
    };
    my ($pkg) = glob "$src/lazysite/backups/$built->{name}";
    ok( $pkg && -f $pkg, 'and the file is there' ) or return;

    # A FRESH instance. It needs the DESCRIPTOR - the export carries the shape
    # to check against, not the declaration - which is itself worth asserting,
    # because a restore onto an instance that has never heard of the table must
    # say so rather than inventing one.
    my $dst = "$base/dst";
    make_path( "$dst/lazysite/backups", "$dst/lazysite/db/tables" );
    for my $pair ( [ "$dst/lazysite.conf", "site_name: t\n" ],
        [ "$dst/lazysite/domains.conf", '' ] )
    {
        open my $fh, '>', $pair->[0] or die $!;
        print {$fh} $pair->[1];
        close $fh;
    }
    local $Lazysite::Manager::SitePackage::DOCROOT = $dst;
    local $Lazysite::Manager::Domains::DOCROOT     = $dst;

    my $nodesc = Lazysite::Manager::SitePackage::package_apply( $pkg,
        content_root => 'client' );
    ok( $nodesc->{ok}, 'the apply itself succeeds' ) or diag( $nodesc->{error} // '' );
    my ($skip) = grep { $_->{table} eq 'products' } @{ $nodesc->{data_skipped} || [] };
    ok( $skip, 'and the table is SKIPPED, not silently dropped' )
        or diag( 'A partial data restore reported as a complete one is the '
            . 'whole failure mode DP-6 exists to remove.' );
    like( $skip->{why}, qr/no descriptor/, 'saying the descriptor is missing' );

    # Now declare it on the far side and apply again.
    open my $dd, '>', "$dst/lazysite/db/tables/products.yaml" or die $!;
    print {$dd} $desc;
    close $dd;
    my $ok = Lazysite::Manager::SitePackage::package_apply( $pkg,
        content_root => 'client2' );
    ok( $ok->{ok}, 'the second apply succeeds' ) or diag( $ok->{error} // '' );
    my ($done) = grep { $_->{table} eq 'products' } @{ $ok->{data_restored} || [] };
    ok( $done, 'the table is restored' )
        or diag( 'skipped: '
            . join( ', ', map { "$_->{table} ($_->{why})" } @{ $ok->{data_skipped} || [] } ) );
    is( $done->{rows}, 2, 'both rows' );

    my $got = read_rows( $dst, 'products', order_by => 'code' )->{rows};
    is( $got->[1]{price}, '120.00', 'and the money kept its trailing zeros' );

    # A THIRD apply onto the now-populated instance must REFUSE, not overwrite.
    my $again = Lazysite::Manager::SitePackage::package_apply( $pkg,
        content_root => 'client3' );
    my ($refused)
        = grep { $_->{table} eq 'products' } @{ $again->{data_skipped} || [] };
    ok( $refused, 'applying onto a populated table is refused' )
        or diag( 'Restoring over live rows replaces a working product list '
            . 'with a snapshot from whenever the package was built, and the '
            . 'operator asked for a site, not for that.' );
    like( $refused->{why}, qr/already holds rows/, 'saying why' );
    is( scalar @{ read_rows( $dst, 'products' )->{rows} }, 2,
        'and the live rows are untouched' );
};

done_testing();
