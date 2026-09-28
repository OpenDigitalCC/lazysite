#!/usr/bin/perl
# SM777: `timestamps: true` created created_at and updated_at, the value layer
# refused them from every writer ("maintained by the plugin"), and nothing ever
# wrote them. A site that turned the flag on to get trustworthy provenance got
# neither a stamp nor its own field back - rows with created_at=None on the
# table with the flag, and a sister table carrying client-supplied "added_at"
# text a writer could forge. Every write path stamps: insert, update, import.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir);

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}

use Lazysite::Data::Tables qw(read_rows apply_schema insert_row update_row import_rows);

my $docroot = site_tempdir();    # a level down: the engine reads the parent (lint 118)
make_path("$docroot/lazysite/db/tables");
open my $fh, '>', "$docroot/lazysite/db/tables/notes.yaml" or die $!;
print {$fh} <<'YAML';
title: Notes
key: id
auto_key: true
timestamps: true
fields:
  body:
    type: text
YAML
close $fh;
ok( apply_schema( $docroot, 'notes' )->{ok}, 'the table is created with the flag on' );

my $ISO = qr/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/;

sub row {
    my ($key) = @_;
    my $r     = read_rows( $docroot, 'notes', as => 'operator' );
    my ($row) = grep { $_->{id} == $key } @{ $r->{rows} };
    return $row;
}

subtest 'an insert is stamped by the plugin, not the writer' => sub {
    my $r = insert_row( $docroot, 'notes', { body => 'first' } );
    ok( $r->{ok}, 'inserted' ) or diag $r->{error};
    my $row = row( $r->{key} );
    like( $row->{created_at}, $ISO, 'created_at is a UTC datetime in the value layer\'s spelling' );
    is( $row->{updated_at}, $row->{created_at}, 'updated_at equals created_at on insert' );

    my $forged = insert_row( $docroot, 'notes', { body => 'x', created_at => '2030-01-01T00:00:00Z' } );
    ok( !$forged->{ok}, 'a writer still cannot supply the stamp' );
    is( $forged->{rule}, 'reserved', 'refused as reserved' );
};

subtest 'an update moves updated_at and leaves created_at' => sub {
    my $r   = insert_row( $docroot, 'notes', { body => 'second' } );
    my $was = row( $r->{key} );
    sleep 1;    # the stamp is to the second
    ok( update_row( $docroot, 'notes', $r->{key}, { body => 'second, edited' },
            as => 'operator' )->{ok}, 'updated' );
    my $now = row( $r->{key} );
    is( $now->{created_at}, $was->{created_at}, 'created_at is unchanged by an update' );
    cmp_ok( $now->{updated_at}, 'gt', $was->{updated_at}, 'updated_at moved forward' );
    like( $now->{updated_at}, $ISO, 'and is still a datetime' );
};

subtest 'a CSV import is stamped too, and does not write the columns it carries' => sub {
    my $r = import_rows( $docroot, 'notes', [ 'body', 'created_at' ], [ [ 'imported', '2001-01-01T00:00:00Z' ] ], apply => 1 );
    ok( $r->{ok}, 'imported' ) or diag $r->{error};
    my $all = read_rows( $docroot, 'notes', as => 'operator' );
    my ($row) = grep { $_->{body} eq 'imported' } @{ $all->{rows} };
    like( $row->{created_at}, $ISO, 'stamped' );
    isnt( $row->{created_at}, '2001-01-01T00:00:00Z', 'with the plugin\'s clock, not the file\'s' );
};

# The field's remaining question: a text field named like a stamp on a table
# without the plugin's stamps is whatever the writer says. The descriptor's
# reply says so.
subtest 'a table without stamps is told which of its fields only look like one' => sub {
    open my $y, '>', "$docroot/lazysite/db/tables/qa.yaml" or die $!;
    print {$y} "title: QA\nkey: qid\nfields:\n  qid:\n    type: text\n    required: true\n  added_at:\n    type: text\n    max: 40\n  saved_at:\n    type: datetime\n  body:\n    type: text\n";
    close $y;
    open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\nplugins:\n  - plugins/data.pl\n";
    close $cf;
    require Lazysite::Manager::Data;
    no warnings 'once';
    $Lazysite::Manager::Data::DOCROOT   = $docroot;
    $Lazysite::Manager::Common::DOCROOT = $docroot;
    my $t = Lazysite::Manager::Data::action_data_table('qa');
    ok( $t->{ok}, 'described' ) or diag $t->{error};
    like( $t->{notes}[0], qr/'added_at', 'saved_at' are written by the caller and can be any value/, 'the note names the fields' );
    like( $t->{notes}[0], qr/created_by, updated_by/, 'and names the author columns the flag adds (SM780)' );
    like( $t->{notes}[0], qr/timestamps: true/, 'and the remedy' );
    my $n = Lazysite::Manager::Data::action_data_table('notes');
    ok( !exists $n->{notes}, 'a table with the plugin\'s stamps carries no note' );
};

# SM780: AND WHO. The actor the caller passes is stamped as created_by and
# updated_by, reserved from the payload on the same terms; a writer with no
# signed-in account leaves them empty rather than guessed.
subtest 'the plugin stamps who wrote the row' => sub {
    my $r = insert_row( $docroot, 'notes', { body => 'signed' }, actor => 'alice' );
    ok( $r->{ok}, 'inserted as alice' ) or diag $r->{error};
    my $row = row( $r->{key} );
    is( $row->{created_by}, 'alice', 'created_by is the actor' );
    is( $row->{updated_by}, 'alice', 'and so is updated_by, on insert' );
    ok( update_row( $docroot, 'notes', $r->{key}, { body => 'edited' }, actor => 'bob',
            as => 'operator' )->{ok}, 'updated as bob' );
    $row = row( $r->{key} );
    is( $row->{created_by}, 'alice', 'created_by is unchanged by an update' );
    is( $row->{updated_by}, 'bob',   'updated_by is the editor' );

    my $forged = insert_row( $docroot, 'notes', { body => 'x', created_by => 'root' }, actor => 'alice' );
    ok( !$forged->{ok} && $forged->{rule} eq 'reserved', 'a writer cannot supply the author' );

    my $anon = insert_row( $docroot, 'notes', { body => 'from a public form' } );
    ok( $anon->{ok},                                'a write with no actor still lands' );
    ok( !defined row( $anon->{key} )->{created_by}, 'and its author is empty, not guessed' );

    my $imp = import_rows( $docroot, 'notes', ['body'], [ ['imported by carol'] ], apply => 1, actor => 'carol' );
    ok( $imp->{ok}, 'imported' ) or diag $imp->{error};
    my $all = read_rows( $docroot, 'notes', as => 'operator' );
    my ($ir) = grep { $_->{body} eq 'imported by carol' } @{ $all->{rows} };
    is( $ir->{created_by}, 'carol', 'an import is stamped with the importer' );
};

# A table that had the flag before the author columns existed gains them as
# an additive migration - the plan says so, and the migrate adds them.
subtest 'an older timestamps table gains the author columns additively' => sub {
    require Lazysite::Data::Connect;
    my $dbh = Lazysite::Data::Connect::write_handle($docroot);
    $dbh->do('CREATE TABLE old_notes (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT, created_at TEXT, updated_at TEXT)');
    open my $y, '>', "$docroot/lazysite/db/tables/old_notes.yaml" or die $!;
    print {$y} "title: Old\nkey: id\nauto_key: true\ntimestamps: true\nfields:\n  body:\n    type: text\n";
    close $y;
    my $r = apply_schema( $docroot, 'old_notes' );
    ok( $r->{ok}, 'the migration applies' ) or diag $r->{error};
    ok( ( grep { /created_by/ } @{ $r->{applied} } ), 'and it added created_by' ) or diag explain $r;
    is_deeply( $r->{blocked}, [], 'nothing blocked - additive only' );
    ok( insert_row( $docroot, 'old_notes', { body => 'after' }, actor => 'dave' )->{ok}, 'and the table takes a stamped row' );
};

done_testing();
