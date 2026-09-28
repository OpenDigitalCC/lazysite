#!/usr/bin/perl
# SM905 U4: A TABLE ROW REACHES THE UPLOADED FILES.
#
# A table handler with keep_copy stored a visitor's photograph under the
# submissions tree and named it in the submissions record. The row an operator
# actually works from - the lead in the table - had nothing: measured before
# this was built, `files=NULL` beside a row whose photograph was on disk two
# directories away. So the expo case the filing came from (a card photographed
# at a stand, a lead worked the next morning) needed the submissions store
# opened by hand to find the picture.
#
# What is held here:
#
#   * the row carries site-relative paths to the files, and the copy and the
#     row name THE SAME directory - the files are written once, under one
#     stamp, because the row now needs the paths before it is written and the
#     order used to be row-then-copy;
#   * a submission with no files leaves the column ALONE. Not an empty string:
#     a column nothing was written to is a submission with no attachment, and
#     one holding '' would read the same way;
#   * the column is checked AT SAVE against the table's own descriptor, and
#     against keep_copy, because a pointer to files the site never keeps is a
#     declaration the code cannot honour (SM807's reason: failing at a
#     visitor's submission is the worst of the two places to find out);
#   * a file that could not be written is NAMED - on the record and in the
#     delivery note - so two files arriving and none landing cannot read as a
#     visitor who attached nothing.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);

use Lazysite::Handlers    ();
use Lazysite::Data::Tables ();

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

# A site with a leads table, the Data extension on, and one table handler.
# $conf is spliced into the handler record, so each subtest states the keys it
# is about and nothing else.
sub fresh_site {
    my ($conf) = @_;
    my $d = site_tempdir();
    make_path( "$d/lazysite/forms", "$d/lazysite/logs", "$d/lazysite/db/tables" );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\nplugins:\n  - plugins/data.pl\n" );
    spit( "$d/lazysite/db/tables/leads.yaml",
        "fields:\n  name:\n    type: text\n  email:\n    type: text\n  files:\n    type: text\n" );
    spit( "$d/lazysite/forms/handlers.conf",
        "handlers:\n  - id: leads\n    type: table\n    name: Leads\n    table: leads\n"
            . "    fields: name=name,email=email\n"
            . ( $conf // "    keep_copy: true\n    files_column: files\n" ) );
    $Lazysite::Handlers::DOCROOT = $d;
    Lazysite::Data::Tables::apply_schema( $d, 'leads' );
    return $d;
}

sub submit {
    my ( $d, $fields, @files ) = @_;
    return Lazysite::Handlers::deliver(
        'leads', $fields,
        origin => 'form',
        source => 'form:contact',
        store  => 'contact',
        ip     => '203.0.113.9',
        ( @files ? ( files => \@files ) : () ),
    );
}

sub rows_of {
    my ($d) = @_;
    my $r = Lazysite::Data::Tables::read_rows( $d, 'leads', as => 'operator' );
    return $r->{rows} // [];
}

sub records_of {
    my ($d) = @_;
    open my $fh, '<', "$d/lazysite/forms/submissions/contact.jsonl" or return [];
    my @recs = map { decode_json($_) } <$fh>;
    close $fh;
    return \@recs;
}

sub dirs_under {
    my ($p) = @_;
    opendir my $dh, $p or return ();
    my @e = sort grep { !/\A\.\.?\z/ } readdir $dh;
    closedir $dh;
    return @e;
}

subtest 'the row names the files, and names the same directory as the copy' => sub {
    my $d = fresh_site();
    my $r = submit(
        $d,
        { name => 'A Person', email => 'p@example.test' },
        { filename => 'card.png',  data => 'PNGDATA', type => 'image/png' },
        { filename => 'notes.pdf', data => 'PDFDATA', type => 'application/pdf' },
    );
    ok( $r->{ok}, 'the submission was delivered' ) or diag( $r->{why} // '' );

    my $rows = rows_of($d);
    is( scalar @$rows, 1, 'one row' ) or return;
    my $cell = $rows->[0]{files};
    ok( defined $cell && length $cell, 'the row carries a value in the files column' ) or return;
    my @paths = split /\s*,\s*/, $cell;
    is( scalar @paths, 2, 'one path per file, not a folder to go looking in' );
    like( $paths[0], qr{\Alazysite/forms/submissions/contact\.files/},
        'site-relative, so it can be pasted into the Files page' );
    like( $paths[0], qr{/card\.png\z},   'in the order the browser sent them: the card first' );
    like( $paths[1], qr{/notes\.pdf\z}, 'then the notes' );
    ok( -e "$d/$paths[0]", 'the first path reaches a file that is there' );
    ok( -e "$d/$paths[1]", 'and so does the second' );

    # THE SAME DIRECTORY, ONE SAVE. The row now needs the paths before it is
    # written, and the copy is what writes the files: get the order wrong and
    # both halves work while naming two different stamped directories.
    my $rec = records_of($d)->[0];
    is_deeply( $rec->{_files}, [ 'card.png', 'notes.pdf' ], 'the copy names the files too' );
    my @dirs = dirs_under("$d/lazysite/forms/submissions/contact.files");
    is( scalar @dirs, 1, 'the files were written ONCE - one stamped directory, not two' );
    like( $paths[0], qr{/\Q$dirs[0]\E/}, 'and it is the directory the row points into' );
    is( "lazysite/forms/submissions/$rec->{_files_dir}/card.png",
        $paths[0], 'the copy and the row agree, path for path' );
};

subtest 'a submission with no files leaves the column alone' => sub {
    my $d = fresh_site();
    ok( submit( $d, { name => 'No Files', email => 'n@example.test' } )->{ok}, 'delivered' );
    my $rows = rows_of($d);
    is( scalar @$rows, 1, 'one row' ) or return;
    # NOT ''. An empty string is a value somebody wrote; undef is a column
    # nothing was written to, which is what "this visitor attached nothing" is.
    ok( !defined $rows->[0]{files},
        'the column is empty rather than holding an empty string' )
        or diag( "got: '" . ( $rows->[0]{files} // '(undef)' ) . "'" );
    ok( !exists records_of($d)->[0]{_files}, 'and the copy names no files either' );
};

subtest 'the column is checked at save, against the table and against keep_copy' => sub {
    my $d    = fresh_site();
    my %base = ( id => 'leads2', type => 'table', name => 'Leads', table => 'leads',
        fields => 'name=name' );
    my $save = sub { Lazysite::Handlers::action_handler_save( { %base, @_ }, unconstrained => 1 ) };

    ok( $save->( files_column => 'files' )->{ok}, 'a column the table has is accepted' );

    my $r = $save->( files_column => 'photo' );
    ok( !$r->{ok}, 'a column the table does not have is refused' );
    like( $r->{error}, qr/files_column: 'leads' has no column photo/, 'naming the column' );
    like( $r->{error}, qr/its columns are: email, files, name/,
        'and listing the ones it does have' );

    # The key is reported AS THE KEY, not as a column that does not exist: an
    # auto key is absent from `fields`, so the existence check would send a
    # sysop looking for a spelling mistake in the one name that is certainly
    # right (Data::Value.pm makes the same point about its own message).
    $r = $save->( files_column => 'id' );
    ok( !$r->{ok}, 'the key is refused' );
    like( $r->{error}, qr/'id' is the key of 'leads'/, 'and refused for being the key' );

    $r = $save->( files_column => 'files', keep_copy => 'false' );
    ok( !$r->{ok}, 'a files column with the submissions copy off is refused' );
    like( $r->{error}, qr/keep_copy: false/, 'naming keep_copy' );
    like( $r->{error}, qr/files_column/,     'and files_column - both keys, because either can move' );

    ok( $save->( keep_copy => 'false' )->{ok},
        'keep_copy: false on its own is still perfectly good' );
};

subtest 'a file that could not be written is named, not dropped' => sub {
    my $d = fresh_site();
    # The per-submission directory cannot be created, so every file's open
    # fails while the record itself still writes: two attached, none stored.
    my $files = "$d/lazysite/forms/submissions/contact.files";
    make_path($files);
    chmod 0555, $files;

    my $r = submit(
        $d,
        { name => 'A Person', email => 'p@example.test' },
        { filename => 'card.png',  data => 'PNGDATA' },
        { filename => 'notes.pdf', data => 'PDFDATA' },
    );
    chmod 0755, $files;
    # STILL ok: the fields arrived, and reporting the submission as failed would
    # throw away a lead over a file. The note is where it says so.
    ok( $r->{ok}, 'the submission is still delivered - the fields did arrive' );
    like( $r->{note} // '', qr/could not be written/, 'the delivery note says files were lost' );
    like( $r->{note} // '', qr/card\.png/,            'naming one' );
    like( $r->{note} // '', qr/notes\.pdf/,           'and the other' );
    like( $r->{note} // '', qr/0 of 2 stored/,        'and how many of how many' );

    my $rec = records_of($d)->[0];
    is_deeply( [ sort @{ $rec->{_files_failed} // [] } ], [ 'card.png', 'notes.pdf' ],
        'the record names the files that were lost' );
    # The discriminating measure: this record must not read like the one in the
    # subtest above, where the visitor attached nothing at all.
    ok( !exists $rec->{_files}, 'and names none as stored' );
    ok( !defined rows_of($d)->[0]{files},
        'the row points at nothing rather than at a file that is not there' );
};

done_testing();
