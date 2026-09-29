#!/usr/bin/perl
# SM857's open question 4: A FORM HANDLER SAYS WHAT ITS ROWS ARE.
#
# The ruling that gave a row a policy also said the time to set one is at WRITE -
# "whatever is creating the row gets to say the policy". A form handler is a writer
# and had nothing to say it with, so every row it wrote came out SHARED. On a table
# that declares row_policy, that is the one outcome the declaration exists to
# prevent, and the filing's own words are that the safe case therefore took extra
# work. It is the piece the expo depends on.
#
# Measured before it was built, on a table declaring row_policy: true, two
# applicants submitting through the handler:
#
#     ROW 1: who=Ann  created_by=ann  row_policy=NULL
#     ROW 2: who=Bob  created_by=bob  row_policy=NULL
#     bob amending ann's row: ok=1
#
# What is held here:
#
#   * a handler declaring `personal` writes rows that belong to their submitter,
#     and the confinement SM857 built then does the rest;
#   * declaring nothing still writes SHARED rows, so no existing handler changes
#     behaviour - the column is left alone rather than written empty;
#   * the value is checked AT SAVE against the store's own vocabulary, not a
#     second copy of it, and `personal` on a table with no policy column is
#     refused there too - SM807's reason, that a visitor's submission is the worst
#     place to find out;
#   * and `personal` WITHOUT AN AUTHENTICATED SUBMITTER is the case worth saying
#     out loud: created_by is empty, so the row belongs to nobody and only an
#     operator can amend it. Safe - more locked down, not less - and almost
#     certainly not what was asked for. The row is still written, because refusing
#     it would lose a submission over a configuration the visitor cannot see.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper             qw(site_tempdir);
use Lazysite::Handlers     ();
use Lazysite::Data::Tables qw(apply_schema read_rows update_row);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

# $policy goes on the handler; $table_policy decides whether the TABLE declares
# the column, so the two can be set independently - which is the mismatch the
# save-time check is about.
sub fresh_site {
    my (%o) = @_;
    my $d = site_tempdir();
    make_path( "$d/lazysite/forms", "$d/lazysite/logs", "$d/lazysite/db/tables" );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\nplugins:\n  - plugins/data.pl\n" );
    spit( "$d/lazysite/db/tables/applications.yaml",
        "title: Applications\ntimestamps: true\n"
            . ( $o{table_policy} // 1 ? "row_policy: true\n" : '' )
            . "fields:\n  who:\n    type: text\n  offer:\n    type: text\n" );
    spit( "$d/lazysite/forms/handlers.conf",
        "handlers:\n  - id: apply\n    type: table\n    name: Applications\n"
            . "    table: applications\n    fields: who=who,offer=offer\n"
            . "    keep_copy: false\n"
            . ( defined $o{policy} ? "    row_policy: $o{policy}\n" : '' ) );
    $Lazysite::Handlers::DOCROOT = $d;
    apply_schema( $d, 'applications' );
    return $d;
}

sub submit {
    my ( $d, $who, $offer ) = @_;
    return Lazysite::Handlers::deliver(
        'apply', { who => ucfirst( $who || 'Anon' ), offer => $offer },
        origin => 'form', source => 'form:apply', store => 'apply',
        ( $who ? ( actor => $who ) : () ),
    );
}

sub rows_of {
    my ($d) = @_;
    my $r = read_rows( $d, 'applications', as => 'operator' );
    return { map { $_->{id} => $_ } @{ $r->{rows} // [] } };
}

subtest 'a handler declaring personal writes rows that belong to their submitter' => sub {
    my $d = fresh_site( policy => 'personal' );
    ok( submit( $d, 'ann', 'application from ann' )->{ok}, 'ann applies' );
    ok( submit( $d, 'bob', 'application from bob' )->{ok}, 'bob applies' );

    my $rows = rows_of($d);
    is( $rows->{1}{row_policy}, 'personal', 'ann\'s row carries the policy' );
    is( $rows->{1}{created_by}, 'ann',      'and her account' );
    is( $rows->{2}{row_policy}, 'personal', 'and bob\'s does too' );

    # THE POINT OF THE WHOLE FILING, end to end: the confinement SM857 built now
    # has something to confine, because the handler said so.
    my $r = update_row( $d, 'applications', 1, { offer => 'bob rewrote it' },
        actor => 'bob', as => { user => 'bob' } );
    ok( !$r->{ok}, 'bob cannot amend ann\'s application' )
        or diag( 'Measured before this was built: ok=1, on a table declaring '
            . 'row_policy: true, because the handler wrote every row shared.' );
    like( $r->{error}, qr/belongs to 'ann'/, 'and the refusal names whose it is' );
    is( rows_of($d)->{1}{offer}, 'application from ann', 'the value is untouched' );

    ok( update_row( $d, 'applications', 1, { offer => 'ann revises it' },
            actor => 'ann', as => { user => 'ann' } )->{ok},
        'and ann still maintains her own' );
};

subtest 'declaring nothing writes shared rows, exactly as before' => sub {
    my $d = fresh_site();    # no row_policy on the handler
    ok( submit( $d, 'ann', 'a' )->{ok}, 'a row is written' );
    # NOT '' - the column is left alone, so it reads as absent, which is what
    # "shared" is. An empty string would be a value somebody wrote.
    ok( !defined rows_of($d)->{1}{row_policy},
        'and carries no policy at all' );
    ok( update_row( $d, 'applications', 1, { offer => 'bob amends it' },
            actor => 'bob', as => { user => 'bob' } )->{ok},
        'so anyone the table admits may amend it - no existing handler changes' );

    # AND ON A TABLE WITH NO POLICY COLUMN AT ALL, which is every table that
    # existed before SM857. This is the case the "declare nothing, send nothing"
    # guard actually protects: sending the key regardless would have the store
    # refuse it - "needs `row_policy: true`" - and every submission through every
    # existing handler would stop. A sabotage that always sent the key passed
    # against a table WITH the column, because Data::Value normalises an empty
    # string to NULL; it is this fixture that can see the difference.
    my $plain = fresh_site( table_policy => 0 );
    my $r     = submit( $plain, 'ann', 'a' );
    ok( $r->{ok}, 'a handler declaring no policy still writes to a table without the column' )
        or diag( $r->{why} // '' );
};

subtest 'the value and the table are checked at save' => sub {
    my $d    = fresh_site();
    my %base = ( id => 'apply2', type => 'table', name => 'A', table => 'applications',
        fields => 'who=who' );
    my $save = sub { Lazysite::Handlers::action_handler_save( { %base, @_ }, unconstrained => 1 ) };

    ok( $save->( row_policy => 'personal' )->{ok}, 'personal is accepted' );
    ok( $save->( row_policy => 'shared' )->{ok},   'so is shared' );
    ok( $save->()->{ok}, 'and declaring nothing' );

    my $r = $save->( row_policy => 'private' );
    ok( !$r->{ok}, 'a misspelt policy is refused AT SAVE' );
    like( $r->{error}, qr/must be one of: personal, shared/, 'naming the two' )
        or diag( 'The vocabulary is the store\'s, read from Data::Owned - a second '
            . 'copy here is a second answer to what a policy may be.' );
    like( $r->{error}, qr/Leave it blank for shared/, 'and what blank means' );
    is( $r->{field}, 'row_policy', 'against the field' );

    # A HANDLER CANNOT DECLARE WHAT THE TABLE CANNOT STORE.
    my $plain = fresh_site( table_policy => 0 );
    $Lazysite::Handlers::DOCROOT = $plain;
    $r                           = $save->( row_policy => 'personal' );
    ok( !$r->{ok}, 'personal on a table with no policy column is refused' );
    like( $r->{error}, qr/does not declare row_policy/, 'saying which side is missing' );
    like( $r->{error}, qr/its rows stay shared/, 'and what blank would do instead' );
    ok( $save->( row_policy => 'shared' )->{ok},
        'while `shared` is fine there - it is what that table already does' );
};

subtest 'personal with no signed-in submitter says so, and still stores the row' => sub {
    my $d = fresh_site( policy => 'personal' );
    # What a PUBLIC form does: no actor, so no created_by.
    my $r = submit( $d, '', 'from a public form' );

    ok( $r->{ok}, 'the row is still stored - a submission is not lost to a config' );
    like( $r->{note} // '', qr/marked personal and the submitter was not signed in/,
        'and the delivery says what happened' )
        or diag( 'personal + no account = a row belonging to nobody. Safe, and '
            . 'almost certainly not what was asked for, which is the combination '
            . 'worth saying out loud rather than either half.' );
    like( $r->{note} // '', qr/only an operator can amend it/, 'and the consequence' );
    like( $r->{note} // '', qr/needs an authenticated form/,   'and the repair' );

    my $row = rows_of($d)->{1};
    is( $row->{row_policy}, 'personal', 'the row is personal as asked' );
    ok( !defined $row->{created_by}, 'and belongs to nobody, which is why' );
};

done_testing();
