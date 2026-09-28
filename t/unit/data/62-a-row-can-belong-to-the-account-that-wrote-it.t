#!/usr/bin/perl
# SM857: A ROW CAN BELONG TO THE ACCOUNT THAT WROTE IT.
#
# Measured before this was built, on a table with timestamps and two accounts
# holding write_data: Bob rewrote Ann's row and then deleted it, and delete_row's
# signature had nowhere to say who was asking. `write_data` is documented as "the
# grant for an app's own users - a learner writing their own submissions, a member
# updating their own record", and it was a grant over every row in the table. Ten
# applicants on one applications table could each edit the other nine's.
#
# WHY NOT A SELECT, which is how every other system does this: no filter in this
# engine is written by the server. A page binding cannot name the viewer (SM856
# keeps it that way on purpose) and the data endpoint's filter comes from the
# caller. So the primitive is not a narrowing of the caller's query - it is the
# engine refusing a KEY the caller named, tested against the one field in a row a
# caller cannot forge.
#
# The design is the release manager's ruling of 2026-09-12, and these are its
# clauses:
#
#   * the row carries an EXPLICIT policy, never one inferred from created_by. An
#     empty created_by already means "written anonymously by a public form", and
#     reading shared out of that absence would give one representation three
#     meanings and let a bug decide an access outcome.
#   * ABSENT MEANS SHARED, in both directions, so existing data needs no
#     migration and a writer that names no policy creates a shared row.
#   * a writer may give their OWN row away and may never take someone else's -
#     the anti-capture rule, which is why naming the policy on a row you do not
#     own is refused whatever that row's current policy is.
#   * a personal row is owned by the account in created_by, and an EMPTY
#     created_by is NOT MINE rather than unknown. That is the deliberate reading
#     for rows written before SM860, and it is what makes them safe.
#   * row_policy needs timestamps, refused by name at load: a personal row with
#     no created_by would be owned by nobody, and an ownership test with no owner
#     to compare admits everybody.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper             qw(site_tempdir);
use Lazysite::Data::Tables qw(apply_schema insert_row update_row delete_row read_rows);
use Lazysite::Data::Descriptor qw(load_descriptor);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $ANN = { user => 'ann' };
my $BOB = { user => 'bob' };

sub fresh_site {
    my ($desc) = @_;
    my $d = site_tempdir();
    make_path("$d/lazysite/db/tables");
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    spit( "$d/lazysite/db/tables/applications.yaml",
        $desc // "title: Applications\ntimestamps: true\nrow_policy: true\n"
            . "fields:\n  who:\n    type: text\n  offer:\n    type: text\n" );
    apply_schema( $d, 'applications' );
    return $d;
}

sub rows_of {
    my ($d) = @_;
    my $r = read_rows( $d, 'applications', as => 'operator' );
    return { map { $_->{id} => $_ } @{ $r->{rows} // [] } };
}

subtest 'a personal row is amended and deleted by its owner, and by nobody else' => sub {
    my $d   = fresh_site();
    my $ann = insert_row( $d, 'applications',
        { who => 'Ann', offer => 'ann-only', row_policy => 'personal' }, actor => 'ann' );
    ok( $ann->{ok}, 'ann writes a personal row' ) or diag( $ann->{error} // '' );

    my $r = update_row( $d, 'applications', $ann->{key}, { offer => 'bob was here' },
        actor => 'bob', as => $BOB );
    ok( !$r->{ok}, 'bob cannot amend it' );
    like( $r->{error}, qr/personal/,         'the refusal says the row is personal' );
    like( $r->{error}, qr/belongs to 'ann'/, 'and whose it is' );
    is( $r->{kind},                          'forbidden', 'refused, not failed' );
    is( rows_of($d)->{ $ann->{key} }{offer}, 'ann-only',  'and the value is untouched' );

    $r = delete_row( $d, 'applications', $ann->{key}, as => $BOB );
    ok( !$r->{ok}, 'nor delete it - removing a row is not a smaller act than amending it' );
    ok( rows_of($d)->{ $ann->{key} }, 'the row is still there' );

    ok( update_row( $d, 'applications', $ann->{key}, { offer => 'ann edits her own' },
            actor => 'ann', as => $ANN )->{ok},
        'ann amends her own row' );
    is( rows_of($d)->{ $ann->{key} }{offer}, 'ann edits her own', 'and it took' );

    # NO OPERATOR BYPASS BY ACCIDENT: the operator is a separate authority, and
    # it is spelt, not inferred from an empty capability set.
    ok( update_row( $d, 'applications', $ann->{key}, { offer => 'the operator can' },
            actor => 'sysop', as => 'operator' )->{ok},
        'an operator amends anybody\'s row' );
    ok( delete_row( $d, 'applications', $ann->{key}, as => 'operator' )->{ok},
        'and deletes it' );
};

subtest 'absent means shared, in both directions' => sub {
    my $d   = fresh_site();
    my $bob = insert_row( $d, 'applications', { who => 'Bob', offer => 'bob-only' },
        actor => 'bob' );
    ok( $bob->{ok}, 'a row written with no policy' );
    ok( !defined rows_of($d)->{ $bob->{key} }{row_policy},
        'carries no policy - NULL, not the string "shared"' );

    ok( update_row( $d, 'applications', $bob->{key}, { offer => 'ann amends it' },
            actor => 'ann', as => $ANN )->{ok},
        'and any writer the table admits may amend it' );

    # The same for a table that never declared the flag: every row shared, which
    # is what every table was before this existed.
    my $plain = fresh_site( "title: A\ntimestamps: true\n"
            . "fields:\n  who:\n    type: text\n  offer:\n    type: text\n" );
    my $row = insert_row( $plain, 'applications', { who => 'Ann', offer => 'a' }, actor => 'ann' );
    ok( update_row( $plain, 'applications', $row->{key}, { offer => 'b' },
            actor => 'bob', as => $BOB )->{ok},
        'a table with no row_policy column is not confined at all' );
};

subtest 'a writer gives their own row away and never takes someone else\'s' => sub {
    my $d   = fresh_site();
    my $bob = insert_row( $d, 'applications', { who => 'Bob', offer => 'bob-only' },
        actor => 'bob' );

    my $r = update_row( $d, 'applications', $bob->{key}, { row_policy => 'personal' },
        actor => 'ann', as => $ANN );
    ok( !$r->{ok}, 'ann cannot make bob\'s shared row personal' );
    like( $r->{error}, qr/not yours/, 'the refusal says whose row it is not' );
    like( $r->{error}, qr/manage_data/,
        'and names the grant that could - taking a shared row private is an '
            . 'amendment to a row you do not own' );
    ok( !defined rows_of($d)->{ $bob->{key} }{row_policy}, 'and nothing was written' );

    ok( update_row( $d, 'applications', $bob->{key}, { row_policy => 'personal' },
            actor => 'bob', as => $BOB )->{ok},
        'bob makes his OWN row personal' );
    is( rows_of($d)->{ $bob->{key} }{row_policy}, 'personal', 'and it took' );

    ok( update_row( $d, 'applications', $bob->{key}, { row_policy => 'shared' },
            actor => 'bob', as => $BOB )->{ok},
        'and can share it again - giving his own row away is his to do' );
    is( rows_of($d)->{ $bob->{key} }{row_policy}, 'shared', 'explicitly shared this time' );
};

subtest 'an empty created_by is NOT MINE, not unknown' => sub {
    my $d = fresh_site();
    # What a public form writes: no actor, so no created_by. The same shape as
    # every row written through the endpoint before SM860.
    my $anon = insert_row( $d, 'applications',
        { who => 'Anon', offer => 'anon', row_policy => 'personal' } );
    ok( $anon->{ok}, 'a personal row written by nobody' );
    ok( !defined rows_of($d)->{ $anon->{key} }{created_by}, 'carries no created_by' );

    for my $who ( $ANN, $BOB, { user => '' } ) {
        my $r = update_row( $d, 'applications', $anon->{key}, { offer => 'mine now' },
            actor => 'x', as => $who );
        ok( !$r->{ok},
            "'" . ( $who->{user} // '' ) . "' cannot claim it" );
        like( $r->{error}, qr/written anonymously/,
            'and the refusal says the row belongs to no account' );
    }
};

subtest 'the policy is a declared value, and the column is a declared flag' => sub {
    my $d = fresh_site();
    my $r = insert_row( $d, 'applications', { who => 'A', row_policy => 'private' },
        actor => 'ann' );
    ok( !$r->{ok}, 'a misspelt policy is refused' );
    like( $r->{error}, qr/must be one of: personal, shared/, 'naming the two' );
    like( $r->{error}, qr/'private' is not one of them/,     'and what was sent' );
    is( $r->{field}, 'row_policy', 'against the field' );

    # A stored 'private' would read as neither personal nor shared and then be
    # treated as absent - which means shared, the opposite of what was asked.
    my $plain = fresh_site( "title: A\ntimestamps: true\n"
            . "fields:\n  who:\n    type: text\n" );
    $r = insert_row( $plain, 'applications', { who => 'A', row_policy => 'personal' },
        actor => 'ann' );
    ok( !$r->{ok}, 'the column cannot be written on a table that does not declare it' );
    like( $r->{error}, qr/row_policy: true/,
        'and the refusal names the flag that would give it to them, not "not a field"' );

    # THE FLAG NEEDS THE STAMPS, refused at load rather than at a visitor's row.
    my $desc = load_descriptor( 'applications',
        { title => 'A', row_policy => 'true', fields => { who => { type => 'text' } } } );
    ok( !$desc->{ok}, 'row_policy without timestamps is refused' );
    like( $desc->{error}, qr/needs timestamps: true/, 'saying which flag' );
    like( $desc->{error}, qr/no created_by to own it/,
        'and why - an ownership test with no owner admits everybody' );
};

subtest 'a write path that does not say who is asking is refused, not permitted' => sub {
    my $d   = fresh_site();
    my $row = insert_row( $d, 'applications', { who => 'A' }, actor => 'ann' );

    # A DIE, deliberately, as read_rows does: there is one caller, so a default
    # here would be a third state in a write gate - "nobody said, so allow" is
    # the shape SM648 describes and this is the dangerous side of it.
    my $ok = eval { update_row( $d, 'applications', $row->{key}, { who => 'B' } ); 1 };
    ok( !$ok, 'update_row without `as` does not quietly write' );
    like( $@, qr/needs to know who is asking/, 'it says what is missing' );

    $ok = eval { delete_row( $d, 'applications', $row->{key} ); 1 };
    ok( !$ok, 'nor does delete_row' );
    like( $@, qr/needs to know who is asking/, 'same sentence, same reason' );
};

done_testing();
