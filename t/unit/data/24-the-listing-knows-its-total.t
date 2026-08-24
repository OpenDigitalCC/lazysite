#!/usr/bin/perl
# SM502 U-1: select_sql has ALWAYS capped a rows read (200 by default,
# 1000 ceiling), so a big table silently showed one page with nothing
# saying so. The reply now carries the total behind the page, so a pager
# can be honest about which slice this is.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use Lazysite::Data::Tables qw(read_rows apply_schema insert_row);

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/db/tables");
open my $df, '>', "$docroot/lazysite/db/tables/things.yaml" or die $!;
print {$df} "title: Things\nkey: slug\nfields:\n  slug:\n    type: text\n";
close $df;
apply_schema( $docroot, 'things' );
insert_row( $docroot, 'things', { slug => "s$_" } ) for 1 .. 5;

subtest 'a limited page still knows the whole count' => sub {
    my $r = read_rows( $docroot, 'things', as => 'operator', limit => 2, offset => 2 );
    ok( $r->{ok}, 'read ok' ) or diag explain $r;
    is( scalar @{ $r->{rows} }, 2, 'the page holds the asked-for slice' );
    is( $r->{total},            5, 'and total counts the table, not the page' );
};

subtest 'an unlimited read agrees with itself' => sub {
    my $r = read_rows( $docroot, 'things', as => 'operator' );
    is( $r->{total},            5, 'total present on the default read too' );
    is( scalar @{ $r->{rows} }, 5, 'and equals the rows when nothing is cut' );
};

done_testing();
