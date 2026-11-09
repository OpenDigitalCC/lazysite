#!/usr/bin/perl
# Ruling 206 (item 16 of the 0.16.9 fault survey): A QUERY THAT FAILED IS NOT AN
# EMPTY TABLE.
#
# Four reads that decide whether a data change is safe swallowed a failed query
# and carried on as though the table held no rows:
#
#   Schema::plan_rebuild - rows with no value for a field made required, a
#       duplicate of a field made unique, a stored value the new type will not
#       take: a failure read as "none", so the rebuild was planned as safe;
#   Schema::plan_migration - a duplicate blocking a new unique index, the same;
#   Tables::import_rows - the existing keys: a failure read as "no rows yet",
#       so every CSV row was planned as an insert over rows that were there.
#
# Each now refuses as cannot-tell, naming lazysite/db/data.sqlite and the check,
# and changes nothing. The query is made to fail here by wrapping the DBI method
# for that one statement - the shape a locked or damaged store produces.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use Lazysite::Data::Tables qw(apply_schema insert_row read_rows import_rows load_table);
use Lazysite::Data::Schema qw(plan_rebuild plan_migration);
use Lazysite::Data::Connect ();

my $docroot = site_tempdir();
make_path( "$docroot/lazysite/db/tables", "$docroot/lazysite/logs" );
my $path = "$docroot/lazysite/db/tables/probe.yaml";

sub describe { open my $f, '>', $path or die $!; print {$f} $_[0]; close $f; return }

# Run $code with every DBI call whose SQL matches $re dying as a store would.
sub failing {
    my ( $re, $code ) = @_;
    my %orig = map { $_ => DBI::db->can($_) } qw(selectrow_array selectrow_arrayref selectcol_arrayref);
    no warnings 'redefine';
    local *DBI::db::selectrow_array    = sub { die "disk I/O error\n" if $_[1] =~ $re; goto &{ $orig{selectrow_array} } };
    local *DBI::db::selectrow_arrayref = sub { die "disk I/O error\n" if $_[1] =~ $re; goto &{ $orig{selectrow_arrayref} } };
    local *DBI::db::selectcol_arrayref = sub { die "disk I/O error\n" if $_[1] =~ $re; goto &{ $orig{selectcol_arrayref} } };
    my $err = '';
    my $r;
    {
        local *STDERR;
        open STDERR, '>', \$err or die $!;
        $r = $code->();
        close STDERR;
    }
    return ( $r, $err );
}

sub refused_as_cannot_tell {
    my ( $r, $err, $what ) = @_;
    ok( !$r->{ok}, "$what: refused" ) or diag explain $r;
    is( $r->{kind}, 'cannot-tell', "$what: as cannot-tell" );
    like( $r->{error}, qr/lazysite\/db\/data\.sqlite could not be queried/, "$what: naming the store" );
    like( $r->{error}, qr/`lazysite check --docroot <docroot>` names the fault/, "$what: and the check" );
    like( $err, qr/cannot tell - lazysite\/db\/data\.sqlite/, "$what: the log names it" );
    return;
}

describe("key: code\nfields:\n  code:\n    type: text\n  qty:\n    type: text\n  when:\n    type: date\n");
apply_schema( $docroot, 'probe' );
insert_row( $docroot, 'probe', { code => 'P1', qty => '5', when => '2026-01-01' } );
insert_row( $docroot, 'probe', { code => 'P2', qty => 'x' } );

subtest 'plan_rebuild: each pre-flight query that fails refuses' => sub {
    describe("key: code\nfields:\n  code:\n    type: text\n  qty:\n    type: integer\n    unique: true\n"
            . "  when:\n    type: date\n    required: true\n");
    my $d   = load_table( $docroot, 'probe' );
    my $dbh = Lazysite::Data::Connect::read_handle($docroot);
    my $ok  = plan_rebuild( $d, $dbh );
    ok( $ok->{ok}, 'with the store answering, a plan is produced' ) or diag explain $ok;
    ok( scalar @{ $ok->{blocked} }, 'and it is blocked by what the rows hold' );

    for my $case ( [ qr/IS NULL\z/, 'the null count' ], [ qr/DISTINCT/, 'the stored values' ],
        [ qr/GROUP BY|HAVING/i, 'the duplicate check' ] )
    {
        my ( $re, $what ) = @$case;
        my ( $r, $err ) = failing( $re, sub { plan_rebuild( $d, $dbh ) } );
        refused_as_cannot_tell( $r, $err, $what );
    }
};

subtest 'plan_migration: a duplicate check that fails refuses' => sub {
    describe("key: code\nfields:\n  code:\n    type: text\n  qty:\n    type: text\n    unique: true\n"
            . "  when:\n    type: date\n");
    my $d   = load_table( $docroot, 'probe' );
    my $dbh = Lazysite::Data::Connect::read_handle($docroot);
    my ( $r, $err ) = failing( qr/GROUP BY|HAVING/i, sub { plan_migration( $d, $dbh ) } );
    refused_as_cannot_tell( $r, $err, 'the unique index' );
};

subtest 'import_rows: a key query that fails refuses, and nothing is imported' => sub {
    describe("key: code\nfields:\n  code:\n    type: text\n  qty:\n    type: text\n  when:\n    type: date\n");
    my ( $r, $err ) = failing( qr/\ASELECT "code" FROM "probe"\z/,
        sub { import_rows( $docroot, 'probe', [qw(code qty)], [ [ 'P1', '9' ], [ 'P3', '1' ] ], apply => 1 ) } );
    refused_as_cannot_tell( $r, $err, 'the import' );
    my $rows = read_rows( $docroot, 'probe', as => 'operator' );
    is( scalar @{ $rows->{rows} || [] }, 2, 'the table still holds its two rows' );
    my ($p1) = grep { $_->{code} eq 'P1' } @{ $rows->{rows} || [] };
    is( $p1->{qty}, '5', 'and P1 is unchanged' );
};

done_testing();
