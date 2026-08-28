#!/usr/bin/perl
# SM682 second half: changing a table's `writable_by` requires manage_users.
#
# THE ESCALATION IT CLOSES. write_data is granted from the group store, under
# SM195's ceiling, so a descriptor cannot hand write access to an account that
# holds nothing. But an agent holding manage_data can EDIT the descriptor, and
# by adding a group to writable_by it widens a group the operator already
# trusted with row-writes on some other table.
#
# SM647 answered the identical question for a domain's allowed_groups on the
# same day: writing an access list needs authority over the thing it names.
# This is that ruling applied to the descriptor.
#
# ONLY A CHANGE IS GATED. Saving a descriptor whose writable_by is untouched -
# which is nearly every save, since the field is rarely edited - must be
# unaffected, or a data admin adding a column suddenly needs manage_users and
# the check becomes something people route around.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);

plan skip_all => 'manager api missing' unless -f repo_root() . '/lazysite-manager-api.pl';

my @ALL = qw(ui manage_data manage_users write_data);
my $s   = new_site(
    root => repo_root(),
    conf => "control_api_enabled: true\nplugins:\n  - plugins/data.pl\n"
);
make_path( $s->docroot . '/lazysite/db/tables' );

sub descriptor {
    my ( $name, $body ) = @_;
    open my $f, '>', $s->docroot . "/lazysite/db/tables/$name.yaml" or die $!;
    print {$f} $body;
    close $f;
}
my $BASE = "key: code\nfields:\n  code:\n    type: text\n";
descriptor( 'notes', $BASE );
descriptor( 'minutes', "key: code\nwritable_by:\n  - secretaries\nfields:\n  code:\n    type: text\n" );

$s->add_user('dataperson');
sub hold { $s->grant( 'dataperson', 'datafolk', [ 'ui', @_ ], \@ALL ) }

sub save {
    my ( $table, $yaml ) = @_;
    return $s->call( 'dataperson', 'data-table-save',
        body => { table => $table, descriptor => $yaml } );
}

subtest 'an unrelated edit does not need manage_users' => sub {
    hold('manage_data');
    my $r = save( 'notes', "key: code\nfields:\n  code:\n    type: text\n  note:\n    type: text\n" );
    ok( $r->{ok}, 'adding a column is unaffected' )
        or diag( 'got: ' . ( $r->{error} // '' )
            . ' - if this needs manage_users, the check is in the wrong place '
            . 'and people will route around it.' );
};

subtest 'a reorder is not a change' => sub {
    hold('manage_data');
    descriptor( 'twogroups',
        "key: code\nwritable_by:\n  - a\n  - b\nfields:\n  code:\n    type: text\n" );
    my $r = save( 'twogroups',
        "key: code\nwritable_by:\n  - b\n  - a\nfields:\n  code:\n    type: text\n" );
    ok( $r->{ok}, 'moving a name up the list is not a change to who may write' )
        or diag( 'Refusing a reorder teaches people the check is noise.' );
};

subtest 'ADDING a group needs manage_users' => sub {
    hold('manage_data');    # deliberately WITHOUT manage_users
    my $r = save( 'minutes',
        "key: code\nwritable_by:\n  - secretaries\n  - learners\nfields:\n  code:\n    type: text\n" );
    ok( !$r->{ok}, 'refused' )
        or diag( 'This is the escalation: widening a group the operator '
            . 'already trusted with write_data elsewhere.' );
    is( $r->{kind}, 'forbidden', 'as a capability matter' );
    like( $r->{error} // '', qr/Users & groups/, 'naming the capability needed' );
    like( $r->{error} // '', qr/rest of the descriptor/,
        'and saying what CAN still be saved without it' );
};

subtest 'REMOVING a group needs it too' => sub {
    # Narrowing is not an escalation, but it is still a change to who may write,
    # and an agent that could freely narrow could lock an operator's own group
    # out of a table. The rule is about the FIELD, not the direction.
    hold('manage_data');
    my $r = save( 'minutes', "key: code\nfields:\n  code:\n    type: text\n" );
    ok( !$r->{ok}, 'clearing the list is refused too' );
};

subtest 'with manage_users it goes through' => sub {
    hold( 'manage_data', 'manage_users' );
    my $r = save( 'minutes',
        "key: code\nwritable_by:\n  - secretaries\n  - learners\nfields:\n  code:\n    type: text\n" );
    ok( $r->{ok}, 'the same edit, with authority over groups' )
        or diag( 'got: ' . ( $r->{error} // '' ) );
};

done_testing();
