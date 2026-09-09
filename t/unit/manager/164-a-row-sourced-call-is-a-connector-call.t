#!/usr/bin/perl
# SM804, from the field on 0.13.9: every row-sourced connector-call returned
# HTTP 500 with an HTML body. Not a refusal - a crash.
#
# THE CAUSE was one wrong subscript: a loaded descriptor carries its table NAME
# under `table`, a string, and row_payload read `$d->{table}{key}` - so it
# dereferenced a string as a hash, died, and a die in a CGI is a 500.
#
# THE REASON IT SHIPPED is this file's subject. The test written for SM579
# phase 2 MOCKED load_table and read_rows, and the mock returned a shape this
# module had invented rather than the one the data layer returns. It proved the
# mapping logic and nothing about the integration, so it passed while the
# feature could not run at all. The reporter put it exactly: "an end-to-end
# connector-call with a populated row_map appears not to be exercised, since
# any such test would have failed."
#
# So THIS test mocks nothing below the connector. A real descriptor, a real
# migration, real rows.
#
# The second half is the reporter's design point, and it is the better one:
# five crashed calls left the connector's record EMPTY. Every row-source
# outcome was decided in the CALLER, outside call(), which is the only place
# that writes the record - so SM771's rule that every refusal is a row did not
# reach any of them. Resolution moved inside call(); these assertions are what
# says it stays there.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);

use Lazysite::Data::Tables        ();
use Lazysite::Manager::Connectors ();

my $d = site_tempdir();
make_path("$d/lazysite/connectors");
$Lazysite::Manager::Connectors::DOCROOT = $d;

# A REAL table: descriptor on disk, migrated, with a real row in it.
my $dir = Lazysite::Data::Tables::descriptor_dir($d);
make_path($dir);
open my $y, '>', "$dir/sm139row.yaml" or die $!;
print {$y} <<'YAML';
key: code
fields:
  code:  { type: text }
  alpha: { type: text }
  beta:  { type: text }
  gamma: { type: text }
YAML
close $y;

# `operator`, not `sysop`. The first version of this test used `sysop` because
# read_rows' own die message said to, which is SM805 - and that guard caught
# this file the moment it existed.
my $mig = Lazysite::Data::Tables::apply_schema( $d, 'sm139row' );
plan skip_all => 'the data layer is not available here'
    unless ref $mig eq 'HASH' && $mig->{ok};
Lazysite::Data::Tables::insert_row( $d, 'sm139row',
    { code => 'r41', alpha => 'A', beta => 'B', gamma => 'SECRET' }, as => 'operator' );

Lazysite::Manager::Connectors::action_connector_save( 'rowsrc', {
        url       => 'http://127.0.0.1:8787/echo',
        row_table => 'sm139row',
        row_map   => { alpha => 'a_out', beta => 'b_out' },
} );

sub calls_for {
    my ($id) = @_;
    # action_connector_calls takes a HASH - the first version of this helper
    # passed a bare id and got "Odd number of elements in hash assignment",
    # which is a warning, not a failure, so it filtered rows for a connector
    # named undef.
    my $r = Lazysite::Manager::Connectors::action_connector_calls( connector => $id );
    return ref $r->{calls} eq 'ARRAY' ? @{ $r->{calls} } : ();
}

# The thing that crashed. It is asserted through the REAL descriptor, which is
# the whole point - the mocked shape had a `key` under `table` and the real one
# does not.
subtest 'a row resolves to a payload of only the mapped columns' => sub {
    my $all = Lazysite::Manager::Connectors::connectors();
    my ( $p, $why ) = Lazysite::Manager::Connectors::row_payload(
        $all->{rowsrc}, 'r41', as => 'operator' );
    ok( $p, 'the row resolves' ) or do { diag $why; return };
    is_deeply( $p, { a_out => 'A', b_out => 'B' },
        'only the mapped columns, under the names the remote expects' );
    ok( !exists $p->{gamma}, 'an unmapped column does not leave' );
    ok( !exists $p->{code},  'and neither does the key' );
};

subtest 'the descriptor key is read where the data layer keeps it' => sub {
    my $t = Lazysite::Data::Tables::load_table( $d, 'sm139row' );
    is( $t->{key}, 'code', 'the key is at $d->{key}' );
    ok( !ref $t->{table}, '$d->{table} is the NAME, a string - not a hash' )
        or diag 'This is what the crash dereferenced.';
};

# The reporter's design point.
subtest 'every row-source outcome is a row in the connector record' => sub {
    Lazysite::Manager::Connectors::action_connector_save( 'norow',
        { url => 'http://127.0.0.1:8787/echo' } );
    Lazysite::Manager::Connectors::action_connector_save( 'nomap',
        { url => 'http://127.0.0.1:8787/echo', row_table => 'sm139row' } );

    my %case = (
        norow  => 'takes no row source',
        nomap  => 'maps no columns',
        rowsrc => 'no row with',
    );
    for my $id ( sort keys %case ) {
        my $before = scalar calls_for($id);
        my $key    = $id eq 'rowsrc' ? 'nosuchkey' : 'r41';
        my $r      = Lazysite::Manager::Connectors::call( $id, {},
            mode   => 'authenticated', caps => { manage_connectors => 1 },
            groups => [], actor => 'op', row => $key, as => 'operator' );
        ok( !$r->{ok}, "$id: refused" );
        like( $r->{error} // '', qr/$case{$id}/, "$id: and says why" );
        my @after = calls_for($id);
        cmp_ok( scalar @after, '>', $before,
            "$id: AND IT IS IN THE RECORD - an outcome nobody can see is not "
                . 'manageable (SM771)' );
        is( $after[-1]{state}, 'refused', "$id: recorded as a refusal" );
    }
};

# A die inside the data layer must not become a 500 either.
subtest 'an internal fault is a recorded refusal, not a crash' => sub {
    no warnings 'redefine';
    local *Lazysite::Data::Tables::load_table = sub { die "boom in the data layer\n" };
    my $before = scalar calls_for('rowsrc');
    my $r      = eval {
        Lazysite::Manager::Connectors::call( 'rowsrc', {},
            mode   => 'authenticated', caps => { manage_connectors => 1 },
            groups => [], actor => 'op', row => 'r41', as => 'operator' );
    };
    ok( !$@, 'the call does not die - a die here is the 500 that started this' )
        or diag $@;
    ok( $r && !$r->{ok}, 'it is a refusal' );
    like( $r->{error} // '', qr/boom in the data layer/,
        'naming what actually went wrong, rather than an HTML error page' );
    cmp_ok( scalar calls_for('rowsrc'), '>', $before, 'and it is recorded' );
};

done_testing;
