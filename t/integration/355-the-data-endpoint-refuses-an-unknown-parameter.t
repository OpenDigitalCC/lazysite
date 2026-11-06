#!/usr/bin/perl
# SM1377 (ruling 131): the data endpoint refuses a query parameter it does not
# read, rather than naming it and answering every row.
#
# SM606 named an unknown parameter (`ignored`, plus a warning) and still
# returned 200 with every row the caller could see, so `?table=t&chunk=AAA`
# looked like a filtered answer to any script that never read `ignored`. Ruling
# 131 made the refusal: 400, `kind: unknown-parameter`, the error naming the
# parameter and the ones the endpoint reads. `_` - the ordinary cache-buster -
# is the one name accepted and left unread, and the four it reads (order_by,
# order, limit, offset) plus table and csrf behave exactly as before.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use TestHelper             qw(repo_root env_passthrough site_tempdir);
use Lazysite::Data::Tables qw(apply_schema insert_row);

my $root    = repo_root();
my $docroot = site_tempdir( extensions => 1 );
make_path( "$docroot/lazysite/db/tables", "$docroot/lazysite/auth" );
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nextensions:\n  - extensions/data.pl\n";
close $cf;
open my $df, '>', "$docroot/lazysite/db/tables/notes.yaml" or die $!;
print {$df} "public: true\nkey: code\nfields:\n  code:\n    type: text\n"
    . "  chunk:\n    type: text\n";
close $df;
apply_schema( $docroot, 'notes' );
insert_row( $docroot, 'notes', { code => "N$_", chunk => ( $_ % 2 ? 'AAA' : 'BBB' ) } )
    for 1 .. 5;

sub hit {
    my ($qs) = @_;
    local %ENV = ( env_passthrough(), DOCUMENT_ROOT => $docroot,
        REQUEST_METHOD => 'GET', QUERY_STRING => $qs );
    my $out      = qx($^X \Q$root/lazysite-data.pl\E 2>/dev/null);
    my ($status) = $out =~ /Status:\s*(\d+)/;
    my ($body)   = $out =~ /\r?\n\r?\n(.*)/s;
    return ( $status // 0, ( eval { decode_json( $body // '' ) } || {} ) );
}

sub codes { return join ',', map { $_->{code} } @{ $_[0]{rows} || [] } }

subtest 'an unknown parameter is refused, with its own kind' => sub {
    my ( $st, $r ) = hit('table=notes&chunk=AAA');
    is( $st, 400, 'a parameter the endpoint does not read is a 400' )
        or diag( explain $r );
    is( $r->{ok},   0,                   'ok:0' );
    is( $r->{kind}, 'unknown-parameter', 'with a kind of its own' );
    ok( !exists $r->{rows}, 'and no rows - an unfiltered answer is not sent' );
    like( $r->{error}, qr/\bchunk\b/, 'the error names the parameter' );
    like( $r->{error}, qr/order_by, order, limit and offset/,
        'and the ones the endpoint reads' );
    is_deeply( $r->{parameters}, ['chunk'], 'and lists it for a script' );

    ( $st, $r ) = hit('table=notes&b=1&a=2&limit=2');
    is( $st, 400, 'two unknowns beside a known one are still refused' );
    like( $r->{error}, qr/parameters: a, b /, 'both named, sorted' );
};

subtest 'the cache-buster `_` is accepted and changes nothing' => sub {
    my ( $st, $r ) = hit('table=notes&_=1700000000');
    is( $st, 200, '`_` is accepted' ) or diag( explain $r );
    is( scalar @{ $r->{rows} || [] }, 5, 'and every row comes back, as without it' );
    ok( !exists $r->{ignored}, 'with no SM606 `ignored` list' );
    ( $st, $r ) = hit('table=notes&order_by=code&order=desc&limit=2&_=9');
    is( codes($r), 'N5,N4', 'beside the read parameters too' );
};

subtest 'the four read parameters, table and csrf are unchanged' => sub {
    my ( $st, $r ) = hit('table=notes');
    is( $st, 200, 'table alone reads' );
    is( codes($r), 'N1,N2,N3,N4,N5', 'every row' );

    ( $st, $r ) = hit('table=notes&order_by=code&order=desc');
    is( codes($r), 'N5,N4,N3,N2,N1', 'order_by + order' );

    ( $st, $r ) = hit('table=notes&order_by=code&limit=2&offset=1');
    is( $st, 200, 'limit + offset' ) or diag( explain $r );
    is( codes($r), 'N2,N3', 'page two of two' );

    ( $st, $r ) = hit('table=notes&limit=nine');
    is( $st, 400, 'a bad value is still the 400 it was' );
    like( $r->{error}, qr/limit must be a whole number/, 'with its own reason' );

    ( $st, $r ) = hit('csrf=1');
    is( $st, 403, 'csrf=1 anonymous is still refused as not signed in' );
    like( $r->{error} // '', qr/not signed in/, 'with the same wording' );
};

done_testing();
