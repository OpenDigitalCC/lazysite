#!/usr/bin/perl
# SM512: every drop and every lossy rebuild writes a safety export under
# lazysite/db/rebuilds/ - and nothing listed them or removed one, so each
# was permanent until an operator's filesystem trip. Five accumulated on
# edge in one day of field testing. The SM508 pattern, for tables: an
# agent authorised to drop was not authorised to tidy.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Data
    qw(action_data_safety_exports action_data_safety_export_delete);

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/db/rebuilds");
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nplugins:\n  - plugins/data.pl\n";
close $cf;
$Lazysite::Manager::Data::DOCROOT = $docroot;
for my $f (qw(zz-dropped-20260824T133544Z.json things-20260824T140000Z.json notes.txt)) {
    open my $fh, '>', "$docroot/lazysite/db/rebuilds/$f" or die $!;
    print {$fh} "{}\n";
    close $fh;
}

subtest 'the exports can be listed, and say what they are' => sub {
    my $r = action_data_safety_exports();
    ok( $r->{ok}, 'listed' ) or diag explain $r;
    my %by = map { $_->{file} => $_ } @{ $r->{exports} };
    is( scalar keys %by, 2, 'only export-shaped files are exports' );
    is( $by{'zz-dropped-20260824T133544Z.json'}{kind},  'dropped', 'a drop export' );
    is( $by{'zz-dropped-20260824T133544Z.json'}{table}, 'zz',      'names its table' );
    is( $by{'things-20260824T140000Z.json'}{kind},      'rebuild', 'a rebuild export' );
    is( $r->{dir}, 'lazysite/db/rebuilds', 'and the reply says where, site-relative' );
};

subtest 'an export can be cleared, by its exact name' => sub {
    my $d = action_data_safety_export_delete('zz-dropped-20260824T133544Z.json');
    ok( $d->{ok}, 'deleted' ) or diag explain $d;
    ok( !-e "$docroot/lazysite/db/rebuilds/zz-dropped-20260824T133544Z.json", 'gone' );
    my $again = action_data_safety_export_delete('zz-dropped-20260824T133544Z.json');
    is( $again->{kind} // '', 'not-found', 'a second delete is an honest not-found' );
};

subtest 'SECURITY: only the minted shape reaches the unlink' => sub {
    for my $bad ( '../lazysite.conf', 'notes.txt', 'things-20260824T140000Z.json/../x',
        '/etc/passwd', 'things-2026.json' ) {
        my $d = action_data_safety_export_delete($bad);
        ok( !$d->{ok}, "refused: $bad" );
        is( $d->{kind} // '', 'name', 'by name, before any filesystem look' );
    }
    ok( -f "$docroot/lazysite/db/rebuilds/notes.txt", 'the stray file is untouched' );
    my $none = action_data_safety_export_delete('');
    ok( !$none->{ok}, 'an empty name is refused' );
};

# --- SM514: read, judge from the listing, offer back ----------------------
use Lazysite::Data::Tables qw(apply_schema insert_row drop_table read_rows);
use Lazysite::Manager::Data
    qw(action_data_safety_export_read action_data_safety_export_restore);

my $DESC = "title: Things\nkey: slug\nfields:\n  slug:\n    type: text\n  name:\n    type: text\n";
sub declare_things {
    make_path("$docroot/lazysite/db/tables");
    open my $df, '>', "$docroot/lazysite/db/tables/things.yaml" or die $!;
    print {$df} $DESC;
    close $df;
    my $r = apply_schema( $docroot, 'things' );
    die explain $r unless $r->{ok};
}

subtest 'SM514: a real drop export can be read, and the listing judges it' => sub {
    plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available'
        unless eval { require DBI; require DBD::SQLite; require YAML::PP; 1 };
    declare_things();
    insert_row( $docroot, 'things', { slug => "s$_", name => "Thing $_" } ) for 1 .. 6;
    my $drop = drop_table( $docroot, 'things', actor => 't', confirm => 'things' );
    ok( $drop->{ok}, 'dropped, with a safety export' ) or diag explain $drop;
    my ($file) = ( $drop->{safety_export} // '' ) =~ m{([^/]+\.json)\z};
    ok( $file, 'the export is named' ) or diag explain $drop;

    my $l = action_data_safety_exports();
    my ($e) = grep { $_->{file} eq $file } @{ $l->{exports} };
    is( $e->{rows}, 6, 'the listing carries the row count' ) or diag explain $e;
    like( join( ' ', @{ $e->{keys} } ), qr/s1 .*\.\.\. s6/, 'and a key sample, first three ... last' );

    my $r = action_data_safety_export_read($file);
    ok( $r->{ok}, 'the export can be READ' ) or diag explain $r;
    is( $r->{row_count}, 6,         'every row' );
    is( $r->{kind},      'dropped', 'named as a drop' );
    ok( !action_data_safety_export_read('../x')->{ok}, 'the read keeps the name guard' );

    my $before = action_data_safety_export_restore($file);
    is( $before->{kind} // '', 'no_such_table',
        'offering back to a dropped table refuses and says to re-declare' )
        or diag explain $before;

    declare_things();
    my $plan = action_data_safety_export_restore($file);
    ok( $plan->{ok} && !$plan->{applied}, 'without apply it is a plan' ) or diag explain $plan;
    is( $plan->{inserts}, 6, 'six inserts planned' );
    my $done = action_data_safety_export_restore( $file, 1 );
    ok( $done->{ok} && $done->{applied}, 'with apply it writes' ) or diag explain $done;
    my $back = read_rows( $docroot, 'things', as => 'operator' );
    is( $back->{total}, 6, 'and the rows are back in the table they came from' );
};

subtest 'SM514: a LOSSY export restores what fits and reports what does not' => sub {
    plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available'
        unless eval { require DBI; require DBD::SQLite; require YAML::PP; 1 };
    my $lossy = 'things-20260823T175821Z.json';
    open my $fh, '>', "$docroot/lazysite/db/rebuilds/$lossy" or die $!;
    print {$fh} qq({"lazysite_data":1,"table":"things","key":"slug","fields":{"slug":{"type":"text"},"name":{"type":"text"},"gone":{"type":"text"}},"rows":[{"slug":"s7","name":"Seven","gone":"lost value"}]}\n);
    close $fh;
    my $r = action_data_safety_export_restore( $lossy, 1 );
    ok( $r->{ok}, 'the restore proceeds' ) or diag explain $r;
    is_deeply( $r->{not_restored_columns}, ['gone'], 'and names the column that could not come back' );
    my $back = read_rows( $docroot, 'things', as => 'operator' );
    is( $back->{total}, 7, 'the row itself is restored' );
};

done_testing();
