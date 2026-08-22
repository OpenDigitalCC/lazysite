#!/usr/bin/perl
# DP-2: the diagnosis that replaced the refusal, and the endpoint sharing the
# page's parser.
#
# WHY A DIAGNOSIS RATHER THAN A RULE. Filtering or ordering on an unindexed
# field was refused at first, on the reasoning that a scan works on a dozen
# test rows and fails on a real table. Measured, at 100,000 rows, warm, best of
# five: an unindexed ORDER BY ... LIMIT 10 costs 5.6 ms and an indexed one
# 0.03 ms. Five milliseconds is noise beside forking a Perl CGI, and these
# tables hold site state - a product list, a directory. The refusal would have
# cost every author of a thirty-row table an index and a migration to sort by
# name, to save a hundredth of a millisecond.
#
# So the query runs and the SLOW ones are reported. THE THRESHOLD IS LOWERED
# HERE rather than the table made large: building 400,000 rows to provoke a
# real 25 ms read would make the suite slow to prove that something else is.
# What must be true is that a read over the threshold produces the warning,
# names the field, and says what to do - and that is what is asserted.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use TestHelper qw(repo_root env_passthrough);
use Lazysite::Data::Tables qw(apply_schema insert_row resolve_binding);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path( "$docroot/lazysite/db/tables", "$docroot/lazysite/auth" );
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nplugins:\n  - plugins/data.pl\n";
close $cf;
open my $df, '>', "$docroot/lazysite/db/tables/notes.yaml" or die $!;
print {$df} "public: true\nkey: code\nfields:\n  code:\n    type: text\n"
    . "  body:\n    type: text\n";
close $df;
apply_schema( $docroot, 'notes' );
insert_row( $docroot, 'notes', { code => "N$_", body => "body $_" } ) for 1 .. 5;

my $visitor = { user => '', groups => [] };

subtest 'a fast read says nothing' => sub {
    my $r = resolve_binding( $docroot, 'notes(order=body)', $visitor );
    ok( $r->{ok}, 'the unindexed order runs' ) or diag( $r->{error} );
    is( scalar @{ $r->{rows} }, 5, 'and returns the rows' );
    ok( !$r->{slow}, 'with no warning, because it was not slow' )
        or diag( 'A warning that fires on a five-row table is a warning '
            . 'nobody will still be reading when it matters.' );
    ok( defined $r->{elapsed_ms}, 'the time is reported either way' );
};

subtest 'a slow read names the field and what to do' => sub {
    local $Lazysite::Data::Tables::SLOW_MS = -1;    # everything is slow now
    my $r = resolve_binding( $docroot, 'notes(order=body)', $visitor );
    ok( $r->{slow}, 'the warning fires' );
    like( $r->{slow}, qr/'body'/, 'naming the field that scans' )
        or diag( 'Told only that a page is slow, an author cannot act. Told '
            . 'which binding and which field, they can.' );
    like( $r->{slow}, qr/add an index/, 'and what to do about it' );
    like( $r->{slow}, qr/outgrown SQLite/,
        'and that a table too big for an index has outgrown the engine' )
        or diag( 'An index on a table that large only moves the problem. The '
            . 'honest advice is a different engine, not a smaller query.' );
};

subtest 'an INDEXED order is never called a scan, however slow the box is'
    => sub {
    local $Lazysite::Data::Tables::SLOW_MS = -1;
    my $r = resolve_binding( $docroot, 'notes(order=code)', $visitor );
    ok( $r->{slow}, 'a slow read still reports the time' );
    unlike( $r->{slow}, qr/add an index/,
        'but does not blame an index that already exists' )
        or diag( 'Telling an author to index the key would send them to fix '
            . 'something that is not broken.' );
};

# --- the endpoint uses the same parser ------------------------------------
sub hit {
    my (%env) = @_;
    local %ENV = ( env_passthrough(), DOCUMENT_ROOT => $docroot,
        REQUEST_METHOD => 'GET', QUERY_STRING => '', %env );
    my $out = qx($^X \Q$root/lazysite-data.pl\E 2>/dev/null);
    my ($status) = $out =~ /Status:\s*(\d+)/;
    my ($body)   = $out =~ /\r?\n\r?\n(.*)/s;
    return ( $status // 0, ( eval { decode_json( $body // '' ) } || {} ) );
}

subtest 'THE ENDPOINT CANNOT INJECT INTO THE GRAMMAR' => sub {
    # The endpoint assembles a binding from the query string, so a value
    # carrying a comma would add a SECOND parameter to the grammar. Smuggling
    # a limit past the cap is the cheap version; the expensive version is
    # whatever the grammar grows next.
    my ( $st, $d1 ) = hit( QUERY_STRING => 'table=notes&order_by=body,limit=99999' );
    is( $st, 400, 'a comma in a field name is refused' )
        or diag( 'If this parses, the query string can write grammar.' );
    like( $d1->{error}, qr/field name/, 'as a bad field name' );

    my ( $st2, $d2 ) = hit( QUERY_STRING => 'table=notes&limit=nine' );
    is( $st2, 400, 'a non-numeric limit is a 400' );

    # EVERY assembled parameter, not just the obvious one. The first version of
    # this subtest checked order_by alone, and sabotage showed the limit check
    # could be deleted without failing anything: `limit=nine` is caught by the
    # grammar anyway, so only an INJECTION distinguishes the two.
    my ( $st4, $d4 ) = hit( QUERY_STRING => 'table=notes&limit=2,order=body' );
    is( $st4, 400, 'a comma in the limit cannot add a second parameter' )
        or diag( 'Every value assembled into the binding has to be checked, '
            . 'not only the one that looked like a name.' );

    # AND NOT A 404. "no such table" for a bad limit sends a caller looking for
    # a table that is sitting right there.
    my ( $st3, $d3 ) = hit( QUERY_STRING => 'table=notes&limit=99999' );
    is( $st3, 400, 'over the row cap is refused' );
    like( $d3->{error}, qr/capped/, 'saying it is a cap' );
};

subtest 'the endpoint and the page agree about one binding' => sub {
    my ( $st, $d1 ) = hit( QUERY_STRING => 'table=notes&order_by=code&order=desc&limit=2' );
    is( $st, 200, 'the endpoint answers' );
    my $r = resolve_binding( $docroot, 'notes(order=-code,limit=2)', $visitor );
    is_deeply( [ map { $_->{code} } @{ $d1->{rows} } ],
        [ map { $_->{code} } @{ $r->{rows} } ],
        'and returns exactly what the page binding does' )
        or diag( 'Two doors into one table with different rules is the SM476 '
            . 'defect, which is why they now share a parser.' );
};

done_testing();
