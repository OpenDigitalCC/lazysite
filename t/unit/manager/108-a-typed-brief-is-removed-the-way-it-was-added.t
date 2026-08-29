#!/usr/bin/perl
# SM696: a typed brief is removed the way it was added.
#
# `brief-append` takes type=row&table=NAME&key=KEY. `brief-delete` took only a
# path, so a caller holding the row's identity - the same three parts it used to
# WRITE the brief - had to list first to learn a path it could compose. The
# field agent hit this and worked it out, which is one run spent on a round
# trip.
#
# On a data-driven site rows are deleted constantly, which is the case SM657 was
# built for, so that round trip is the common path rather than an edge case.
#
# Resolved through `typed_rel`, the same function the append uses: the two verbs
# must not hold separate ideas of where an entry lives (SM578).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";

use Lazysite::Manager::Briefs ();

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/briefs");
open my $c, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$c} "site_name: T\nplugins:\n  - plugins/briefs.pl\n";
close $c;
$Lazysite::Manager::Briefs::DOCROOT = $docroot;
{
    no warnings 'redefine', 'once';
    *Lazysite::Manager::Briefs::_gate = sub { undef };
}

sub add {
    return Lazysite::Manager::Briefs::action_brief_append(
        undef, 'why this row is as it is',
        type => 'row', table => $_[0], key => $_[1] );
}
sub del_parts {
    return Lazysite::Manager::Briefs::action_brief_delete(
        undef, type => 'row', table => $_[0], key => $_[1] );
}

subtest 'the parts that created an entry can remove it' => sub {
    my $a = add( 'orders', 'r1' );
    ok( $a->{ok}, 'appended by type/table/key' ) or diag( $a->{error} // '' );
    is( $a->{path}, '.typed/row/orders/r1', 'at the composed path' );

    my $d = del_parts( 'orders', 'r1' );
    ok( $d->{ok}, 'and removed by the same three parts' )
        or diag( 'The caller already holds the row identity. Making it list '
            . 'first to learn a path it can compose is a round trip for '
            . 'nothing, on the operation this feature exists for.' );
};

subtest 'a repeat delete is not-found, not a false success' => sub {
    add( 'orders', 'r2' );
    ok( del_parts( 'orders', 'r2' )->{ok}, 'first delete succeeds' );
    my $again = del_parts( 'orders', 'r2' );
    ok( !$again->{ok}, 'the second is refused' );
    is( $again->{kind}, 'not-found', 'and says why' )
        or diag( 'Reporting ok on a delete that removed nothing tells a caller '
            . 'it cleaned up when it did not.' );
};

subtest 'the same validation applies as on the way in' => sub {
    my $bad = Lazysite::Manager::Briefs::action_brief_delete(
        undef, type => 'row', table => 'a/b', key => 'r1' );
    ok( !$bad->{ok}, 'a slash in the table is refused' )
        or diag( 'The parts compose a PATH. A delete that accepted a slash '
            . 'where the append refuses one would reach entries the append '
            . 'could never have written - a traversal by the back door.' );
    like( $bad->{error}, qr/invalid table/, 'naming the offending part' );

    my $missing = Lazysite::Manager::Briefs::action_brief_delete(
        undef, type => 'row', table => 'orders' );
    ok( !$missing->{ok}, 'and an incomplete reference is refused' );
};

subtest 'a path still works for a caller that has one' => sub {
    add( 'orders', 'r3' );
    my $d = Lazysite::Manager::Briefs::action_brief_delete('.typed/row/orders/r3');
    ok( $d->{ok}, 'the path form is unchanged' )
        or diag( 'briefs-list reports paths. A caller holding one should not '
            . 'have to take it apart to delete the entry.' );
};

done_testing();
