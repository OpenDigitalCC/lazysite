#!/usr/bin/perl
# SM468: what the schema used to be, and who changed it. Derivation is a
# perfect account of NOW and no account of BEFORE - so apply, rebuild and
# drop each append a row to an internal store table. IN THE STORE, so the
# record travels with the data through backup and restore by construction;
# a file beside the database is exactly the desync the D2 decision removed.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use Lazysite::Data::Tables qw(apply_schema schema_history);
use Lazysite::Data::Tables ();

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/db/tables");

sub declare {
    my ( $name, $yaml ) = @_;
    open my $fh, '>', "$docroot/lazysite/db/tables/$name.yaml" or die $!;
    print {$fh} $yaml;
    close $fh;
}

declare( 'events', "title: Events\nkey: slug\nfields:\n  slug:\n    type: text\n  title:\n    type: text\n" );

subtest 'AN APPLY IS REMEMBERED, WITH ITS ACTOR' => sub {
    my $r = apply_schema( $docroot, 'events', actor => 'alice' );
    ok( $r->{ok}, 'applied' ) or diag explain $r;
    my $h = schema_history( $docroot, 'events' );
    is( scalar @$h,     1,       'one history row' );
    is( $h->[0]{op},    'apply', 'op recorded' );
    is( $h->[0]{actor}, 'alice', 'actor recorded' );
    ok( $h->[0]{at} =~ /^\d{4}-\d{2}-\d{2}T/,    'timestamped' );
    ok( ref $h->[0]{detail}{applied} eq 'ARRAY', 'and what happened' );
};

subtest 'a rebuild records what it LOST, and where the safety export went' => sub {
    # Narrow the descriptor: title goes away - a rebuild-only change.
    declare( 'events', "title: Events\nkey: slug\nfields:\n  slug:\n    type: text\n" );
    my $r = Lazysite::Data::Tables::rebuild_table( $docroot, 'events',
        actor => 'bob', confirm_lost => ['title'] );
    ok( $r->{ok}, 'rebuilt' ) or diag explain $r;
    my ($row) = grep { $_->{op} eq 'rebuild' } @{ schema_history( $docroot, 'events' ) };
    ok( $row, 'rebuild row present' );
    is( $row->{actor}, 'bob', 'attributed' );
    is_deeply( $row->{detail}{lost}, ['title'], 'the lost columns are named' );
    like( $row->{detail}{safety_export}, qr{^lazysite/db/rebuilds/},
        'and the receipt is pointed at' );
};

subtest 'THE HISTORY TRAVELS WITH THE STORE' => sub {
    # The restore case that killed the state-file idea: copy data.sqlite into
    # a fresh docroot and the history must answer there, because it IS data.
    my $fresh = tempdir( CLEANUP => 1 );
    make_path("$fresh/lazysite/db/tables");
    copy( "$docroot/lazysite/db/data.sqlite", "$fresh/lazysite/db/data.sqlite" ) or die $!;
    my $h = schema_history( $fresh, 'events' );
    cmp_ok( scalar @$h, '>=', 2, 'the record arrived with the rows' )
        or diag( 'A file beside the database would have stayed behind - the '
            . 'desync D2 removed, reintroduced.' );
};

subtest 'a drop is the last entry, and the internal table is invisible' => sub {
    my $r = Lazysite::Data::Tables::drop_table( $docroot, 'events',
        actor => 'carol', confirm => 'events' );
    ok( $r->{ok}, 'dropped' ) or diag explain $r;
    my ($row) = grep { $_->{op} eq 'drop' } @{ schema_history( $docroot, 'events' ) };
    ok( $row, 'the drop is on the record - the table is gone, the story is not' );
    is( $row->{actor}, 'carol', 'attributed' );
    ok( !( grep { $_ eq '_schema_history' } @{ Lazysite::Data::Tables::list_tables($docroot) } ),
        'the history table appears in no listing - listings are descriptor-driven '
            . 'and a declared name cannot start with an underscore' );
};

subtest 'a table with no recorded changes answers an empty history' => sub {
    declare( 'quiet', "title: Q\nkey: k\nfields:\n  k:\n    type: text\n" );
    is_deeply( schema_history( $docroot, 'quiet' ), [],
        'absence of history is a fact, not an error - every pre-SM468 table looks like this' );
};

done_testing();
