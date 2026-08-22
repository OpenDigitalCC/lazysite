#!/usr/bin/perl
# SM476: the two controls that decide who reads a table, and how they compose.
#
#   `public:` in the descriptor - may an ANONYMOUS visitor see these rows?
#                                 DEFAULT FALSE.
#   the read list in acls.json  - which accounts and groups may see them, in
#                                 the same store and the same shape as a file's
#                                 ACL.
#
# THE CASE THIS FILE EXISTS FOR is the last one: a table marked public that
# ALSO carries a read list. Nothing in Access.pm special-cases it - an
# anonymous visitor matches no entry in a list, and _acl_allows already answers
# false for exactly that reason. The behaviour is right by construction, which
# is worth an assertion precisely BECAUSE nobody wrote code for it: the day
# somebody "fixes" the composition, this is what tells them they broke it.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../../lib";

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use TestHelper qw(repo_root);
use Lazysite::Data::Access ();
use Lazysite::Data::Descriptor qw(load_descriptor);

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/auth");

sub desc {
    my (%o) = @_;
    my $d = load_descriptor( ( $o{name} // 'notes' ),
        { ( $o{public} ? ( public => 1 ) : () ),
            fields => { code => { type => 'text' } } } );
    ok( $d->{ok}, 'the descriptor loads' ) or diag( $d->{error} );
    return $d;
}

sub set_acl {
    my ($map) = @_;
    open my $fh, '>', "$docroot/lazysite/auth/acls.json" or die $!;
    print {$fh} encode_json($map);
    close $fh;
}

sub may {
    my ( $d, @as ) = @_;
    return Lazysite::Data::Access::may_read( $docroot, $d,
        ( @as == 1 ? $as[0] : { user => $as[0], groups => $as[1] } ) );
}

subtest 'a table is closed until it is published' => sub {
    set_acl( {} );
    my $shut = desc( public => 0 );
    my $open = desc( public => 1 );

    ok( !may( $shut, '', [] ), 'an anonymous visitor is refused an unpublished table' )
        or diag( 'This is the default, and it is the whole point: forgetting '
            . 'to write an ACL must not expose a table.' );
    ok( may( $open, '', [] ), 'and allowed a published one' );

    ok( may( $shut, 'alice', [] ),
        'a signed-in account reads an unpublished table' )
        or diag( '`public` is about ANONYMOUS visitors. Restricting which '
            . 'signed-in accounts may read is the ACL read list.' );
};

subtest 'an operator is not asked' => sub {
    set_acl( { 'lazysite/db/tables/notes' => { read => ['nobody'] } } );
    ok( may( desc( public => 0 ), 'operator' ),
        'a manage_data-gated surface reads regardless' )
        or diag( 'The manager, MCP and the API have already asked the '
            . 'capability question. Asking it twice, differently, is how two '
            . 'answers to one question get into a system.' );
};

subtest 'the read list narrows, in the same shape a file ACL uses' => sub {
    set_acl( { 'lazysite/db/tables/notes' => { read => [ 'alice', '@staff' ] } } );
    my $d = desc( public => 0 );

    ok( may( $d, 'alice', [] ),   'a named account reads' );
    ok( !may( $d, 'mallory', [] ), 'an unnamed one does not' );
    ok( may( $d, 'bob', ['staff'] ), 'an @group entry matches a member' );
    ok( !may( $d, 'bob', ['guests'] ), 'and not a non-member' );
};

subtest 'PUBLIC PLUS A READ LIST REFUSES THE ANONYMOUS VISITOR' => sub {
    # The composition nobody wrote code for. A list that names accounts cannot
    # name an anonymous one, so the list decides and the answer is no.
    set_acl( { 'lazysite/db/tables/notes' => { read => ['alice'] } } );
    my $d = desc( public => 1 );

    ok( !may( $d, '', [] ),
        'published, but a read list governs and anonymous matches nothing' )
        or diag( 'If this passes, `public: true` has become an override that '
            . 'defeats the ACL an operator wrote - the two controls must '
            . 'compose, not compete.' );
    ok( may( $d, 'alice', [] ), 'and the named account still reads it' );
};

subtest 'a rule on the tables directory governs every table' => sub {
    # Longest-prefix matching, inherited from the file ACL matcher rather than
    # reimplemented - which is the reason the ACL key is the descriptor's own
    # path and not a table-shaped invention.
    set_acl( { 'lazysite/db/tables' => { read => ['@staff'] } } );
    my $d = desc( public => 1 );
    ok( may( $d, 'bob', ['staff'] ), 'a member of the governing group reads' );
    ok( !may( $d, 'bob', [] ), 'and a non-member does not, without a per-table rule' )
        or diag( 'An operator who locks lazysite/db/tables expects it to '
            . 'cover the tables inside it.' );
};

subtest 'a caller that does not say who is asking gets nothing' => sub {
    set_acl( {} );
    my $d = desc( public => 1 );
    ok( !Lazysite::Data::Access::may_read( $docroot, $d, undef ),
        'undef is refused' );
    ok( !Lazysite::Data::Access::may_read( $docroot, $d, 'anyone' ),
        'and so is a string that is not the word operator' )
        or diag( 'Only "operator" bypasses. A typo must fail closed.' );
};

done_testing();
