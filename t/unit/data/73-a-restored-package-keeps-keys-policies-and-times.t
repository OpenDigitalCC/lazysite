#!/usr/bin/perl
# P21 restore gaps (WORK-PLAN-0154, ruled 2026-10-12): "(1) restore auto-key
# tables, (2) keep row_policy, (3) keep original timestamps".
#
# Found while building SM996 and recorded as its open questions:
#   1. a site package could not restore a table whose key the store assigns -
#      the export carried the key and the import refused a supplied auto key,
#      so the table landed in data_skipped;
#   2. row_policy did not travel, so a personal row came back shared, and any
#      writer the table admits could amend it;
#   3. created_at/updated_at were the time of the restore.
# Now a restore keeps each row's key (the sequence continues after the
# highest), its policy (a personal row is restored personal, to the same
# owner) and its timestamps, and the log names what was kept and who applied
# it. A package without these fields keeps today's behaviour.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir run_cmd);

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}

use JSON::PP                ();
use Lazysite::Data::Connect ();
use Lazysite::Data::Export  ();
use Lazysite::Data::Tables  qw(apply_schema insert_row update_row delete_row read_rows);
use Lazysite::Manager::SitePackage ();
use Lazysite::Manager::Domains     ();

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

sub slurp { my ($p) = @_; open my $fh, '<', $p or die "$p: $!"; local $/; my $t = <$fh>; close $fh; return $t }

# An auto-key table (no `key:`) with timestamps and row_policy.
my $DESC = "title: Notes\ntimestamps: true\nrow_policy: true\nfields:\n  body:\n    type: text\n";

sub instance {
    my (%o) = @_;
    my $d = site_tempdir();
    make_path( "$d/lazysite/backups", "$d/lazysite/db/tables" );
    spit( "$d/lazysite.conf",                 "site_name: t\n" );
    spit( "$d/lazysite/domains.conf",         '' );
    spit( "$d/index.md",                      "---\ntitle: Home\n---\nHome\n" );
    spit( "$d/lazysite/db/tables/notes.yaml", $o{desc} // $DESC );
    apply_schema( $d, 'notes' );
    return $d;
}

my @logged;
{
    no warnings 'redefine';
    my $real = \&Lazysite::Manager::SitePackage::log_event;
    *Lazysite::Manager::SitePackage::log_event = sub { push @logged, [@_]; return $real->(@_) };
}

sub package_of {
    my ($src) = @_;
    local $Lazysite::Manager::SitePackage::DOCROOT   = $src;
    local $Lazysite::Manager::SitePackage::auth_user = 'packer';
    local $Lazysite::Manager::Domains::DOCROOT       = $src;
    my $b = Lazysite::Manager::SitePackage::package_create( '(default)', data_tables => ['notes'] );
    die $b->{error} // 'package failed' unless $b->{ok};
    my ($pkg) = glob "$src/lazysite/backups/$b->{name}";
    return $pkg;
}

sub apply_as {
    my ( $pkg, $dst, $who ) = @_;
    local $Lazysite::Manager::SitePackage::DOCROOT   = $dst;
    local $Lazysite::Manager::SitePackage::auth_user = $who;
    local $Lazysite::Manager::Domains::DOCROOT       = $dst;
    @logged = ();
    return Lazysite::Manager::SitePackage::package_apply( $pkg, content_root => 'client' );
}

sub rows_of {
    my ($d) = @_;
    return { map { $_->{body} => $_ } @{ read_rows( $d, 'notes', as => 'operator' )->{rows} } };
}

# Timestamps a restore cannot produce by accident: written into the source
# store directly, the way rows written months ago carry them.
my %WHEN = (
    'alice-personal' => [ '2025-01-02T03:04:05Z', '2025-02-03T04:05:06Z' ],
    'bob-shared'     => [ '2025-03-04T05:06:07Z', '2025-03-04T05:06:07Z' ],
    'carol-unmarked' => [ '2024-12-31T23:59:59Z', '2025-06-07T08:09:10Z' ],
);

sub source {
    my $src = instance();
    my %key;
    $key{'alice-personal'} = insert_row( $src, 'notes', { body => 'alice-personal', row_policy => 'personal' },
        actor => 'alice' )->{key};
    $key{gone} = insert_row( $src, 'notes', { body => 'gone' }, actor => 'alice' )->{key};
    $key{'bob-shared'} = insert_row( $src, 'notes', { body => 'bob-shared', row_policy => 'shared' },
        actor => 'bob' )->{key};
    $key{'carol-unmarked'} = insert_row( $src, 'notes', { body => 'carol-unmarked' }, actor => 'carol' )->{key};
    # A gap in the keys, so "kept" is not the same as "renumbered from 1".
    delete_row( $src, 'notes', $key{gone}, as => 'operator' );
    my $dbh = DBI->connect( 'dbi:SQLite:dbname=' . Lazysite::Data::Connect::store_path($src),
        '', '', { RaiseError => 1 } );
    for my $b ( sort keys %WHEN ) {
        $dbh->do( 'UPDATE notes SET created_at = ?, updated_at = ? WHERE id = ?',
            undef, @{ $WHEN{$b} }, $key{$b} );
    }
    $dbh->disconnect;
    return ( $src, \%key );
}

subtest 'an auto-key table is restored, each row keeping its key' => sub {
    my ( $src, $key ) = source();
    my $dst = instance();
    my $r   = apply_as( package_of($src), $dst, 'dora' );
    ok( $r->{ok}, 'the apply succeeds' ) or diag( $r->{error} );
    is_deeply( $r->{data_skipped}, [], 'nothing skipped' );
    my ($done) = grep { $_->{table} eq 'notes' } @{ $r->{data_restored} || [] };
    is( $done->{rows}, 3, 'three rows restored' );
    my $got = rows_of($dst);
    is( $got->{$_}{id}, $key->{$_}, "$_ keeps its key ($key->{$_})" ) for sort keys %WHEN;
    my $next = insert_row( $dst, 'notes', { body => 'new' }, actor => 'dora' );
    is( $next->{key}, 1 + $key->{'carol-unmarked'}, 'the sequence continues after the highest' );
};

subtest 'a personal row is restored personal, to the same owner' => sub {
    my ($src) = source();
    my $dst   = instance();
    my $r     = apply_as( package_of($src), $dst, 'dora' );
    my $got   = rows_of($dst);
    is( $got->{'alice-personal'}{row_policy}, 'personal', 'alice\'s personal row is personal' );
    is( $got->{'alice-personal'}{created_by}, 'alice',  '...and hers' );
    is( $got->{'bob-shared'}{row_policy},     'shared', 'a shared row is shared' );
    is( $got->{'carol-unmarked'}{row_policy}, undef, 'an unmarked row stays unmarked' );
    my $amend = update_row( $dst, 'notes', $got->{'alice-personal'}{id}, { body => 'taken' },
        actor => 'bob', as => { user => 'bob' } );
    ok( !$amend->{ok}, 'another writer may not amend it' );
    is( $amend->{rule} // '', 'row_owner', '...refused as someone else\'s personal row' );
    ok( update_row( $dst, 'notes', $got->{'alice-personal'}{id}, { body => 'alice-personal' },
            actor => 'alice', as => { user => 'alice' } )->{ok},
        'its owner may' );
};

subtest 'created_at and updated_at come back as exported' => sub {
    my ($src) = source();
    my $dst   = instance();
    my $r     = apply_as( package_of($src), $dst, 'dora' );
    my $got   = rows_of($dst);
    for my $b ( sort keys %WHEN ) {
        is( $got->{$b}{created_at}, $WHEN{$b}[0], "$b: created_at as exported" );
        is( $got->{$b}{updated_at}, $WHEN{$b}[1], "$b: updated_at as exported" );
    }
};

subtest 'the restore is logged with what it kept and who applied it' => sub {
    my ($src)  = source();
    my $dst    = instance();
    my $r      = apply_as( package_of($src), $dst, 'dora' );
    my ($done) = grep { $_->{table} eq 'notes' } @{ $r->{data_restored} || [] };
    is( $done->{keys_kept},     3, 'data_restored: keys kept' );
    is( $done->{times_kept},    3, '...timestamps kept' );
    is( $done->{policies_kept}, 2, '...policies kept (the unmarked row has none)' );
    is( $done->{authors_kept},  3, '...authors kept, as before' );
    my ($line) = grep { $_->[2] eq 'table rows restored' } @logged;
    ok( $line, 'the restore is logged per table' ) or return;
    my %f = @{$line}[ 3 .. $#$line ];
    is( $f{user}, 'dora', 'naming the account that applied it' );
    is( "$f{keys_kept}/$f{times_kept}/$f{policies_kept}/$f{authors_kept}", '3/3/2/3', 'and what was kept' );
};

subtest 'a package without these fields keeps today\'s behaviour' => sub {
    my ($src) = source();
    my $pkg = package_of($src);
    # Rebuild it as a package written before the fields travelled: the export
    # carries the rows (an auto key included, as export_table always wrote it)
    # and no side maps.
    my $x = site_tempdir();
    run_cmd( 'tar', 'xzf', $pkg, '-C', $x );
    my $json   = JSON::PP->new->canonical->pretty;
    my $export = $json->decode( slurp("$x/data/notes.json") );
    ok( exists $export->{$_}, "the new package carries '$_'" ) for qw(times policies);
    delete @{$export}{qw(times policies authors)};
    spit( "$x/data/notes.json", $json->encode($export) );
    my $old = "$x.tar.gz";
    run_cmd( 'tar', 'czf', $old, '-C', $x, '.' );

    my $dst = instance();
    my $r   = apply_as( $old, $dst, 'dora' );
    ok( $r->{ok}, 'the apply succeeds' ) or diag( $r->{error} );
    my ($done) = grep { $_->{table} eq 'notes' } @{ $r->{data_restored} || [] };
    is( $done->{rows}, 3, 'its rows are restored' );
    is( "$done->{times_kept}/$done->{policies_kept}/$done->{authors_kept}", '0/0/0', 'nothing kept that it does not carry' );
    my $got = rows_of($dst);
    is( $got->{'alice-personal'}{created_by}, 'dora', 'the rows are the applier\'s' );
    is( $got->{'alice-personal'}{row_policy}, undef,  'with no policy' );
    isnt( $got->{'alice-personal'}{created_at}, $WHEN{'alice-personal'}[0], 'and the restore\'s time' );
};

subtest 'an exported key is kept only when asked for, and only a whole number' => sub {
    my $d    = instance();
    my $desc = Lazysite::Data::Tables::load_table( $d, 'notes' );
    my $exp  = sub {
        my ($id) = @_;
        return Lazysite::Data::Export::export_table( $desc, [ { id => $id, body => 'x' } ] );
    };
    my $r = Lazysite::Data::Export::import_table( $desc, $exp->(5) );
    ok( !$r->{ok}, 'without keep_auto_key, a supplied auto key is refused as before' );
    $r = Lazysite::Data::Export::import_table( $desc, $exp->(5), keep_auto_key => 1 );
    ok( $r->{ok}, 'with it, the row is read' );
    is( $r->{rows}[0]{id}, 5, '...keeping its key' );
    for my $bad ( [ 'zero', 0 ], [ 'negative', -2 ] ) {
        my $data = $exp->(1);
        $data->{rows}[0]{id} = $bad->[1];
        ok( !Lazysite::Data::Export::import_table( $desc, $data, keep_auto_key => 1 )->{ok},
            "a key that is $bad->[0] is refused" );
    }
    my $data = $exp->(1);
    $data->{rows}[0]{id} = 'x9';
    ok( !Lazysite::Data::Export::import_table( $desc, $data, keep_auto_key => 1 )->{ok},
        'a key that is not a number is refused' );
};

subtest 'what a restore may keep is checked, and only with an actor' => sub {
    my $d = instance();
    my %t = ( created_at => '2025-01-02T03:04:05Z', updated_at => '2025-01-02T03:04:05Z' );
    my $r = insert_row( $d, 'notes', { body => 'n1' }, times => \%t );
    ok( !$r->{ok}, 'times with no actor are refused' );
    $r = insert_row( $d, 'notes', { body => 'n2' }, auto_key => 7 );
    ok( !$r->{ok}, 'a key with no actor is refused' );
    for my $bad ( [ 'not a mapping', 'yesterday' ],
        [ 'an unknown column', { created_by => 'x' } ],
        [ 'not a date',        { created_at => 'yesterday' } ],
        [ 'not a real date',   { created_at => '2025-02-30T00:00:00Z' } ] )
    {
        ok( !insert_row( $d, 'notes', { body => 'n3' }, actor => 'dora', times => $bad->[1] )->{ok},
            "times: $bad->[0] is refused" );
    }
    for my $bad ( [ 'zero', 0 ], [ 'negative', -3 ], [ 'not a number', 'x7' ], [ 'a fraction', '2.5' ] ) {
        ok( !insert_row( $d, 'notes', { body => 'n4' }, actor => 'dora', auto_key => $bad->[1] )->{ok},
            "a key: $bad->[0] is refused" );
    }
    is( scalar keys %{ rows_of($d) }, 0, 'none of them wrote a row' );

    my $natural = instance( desc => "title: Notes\nkey: code\nfields:\n  code:\n    type: text\n" );
    ok( !insert_row( $natural, 'notes', { code => 'A' }, actor => 'dora', auto_key => 3 )->{ok},
        'a key is refused for a table whose key is not the store\'s' );

    $r = insert_row( $d, 'notes', { body => 'n5' }, actor => 'dora', times => \%t, auto_key => 41 );
    ok( $r->{ok}, 'well-formed times and key are written' ) or diag( $r->{error} );
    is( $r->{key},                     41,                     '...the row at that key' );
    is( rows_of($d)->{n5}{created_at}, '2025-01-02T03:04:05Z', '...at that time' );
};

done_testing();
