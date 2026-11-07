#!/usr/bin/perl
# SM1393: THE AGENT ROLES AND THE SHIPPED BUNDLES REACH A SITE THE `seeded`
# MARK NEVER REACHED.
#
# Both adoptions (_adopt_added_bundles, SM1118/SM1241/SM1262; _adopt_agent_roles,
# SM1371) returned before doing anything unless some group record carried
# `seeded`. A site bootstrapped before SM608 wrote the mark, or whose manager
# group the conf migration wrote without it, carries it on no record, so it
# adopted nothing from any later release, for ever: the 0.16.6 edge site loaded
# its Users page many times and had neither the four roles nor the bundles.
#
# Now a BOOTSTRAPPED site (a manager group is there) adopts once. Whether the
# store carries the mark is read from the manager group: where it does, SM608's
# reading holds and an unmarked record is operator-made; where it does not,
# present by a shipped name is what the store can say. SM1262's record keeps
# the rest: a deleted role or bundle never returns, and an unreadable record
# adopts nothing.
#
# With the change reverted: the first subtest's roles and bundles stay absent.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir run_cmd run_child);

my $tool = "$FindBin::Bin/../../../tools/lazysite-users.pl";

sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; $t }
sub spit  { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh }
sub cli   { my ( $d, @a ) = @_; return run_cmd( $^X, $tool, '--docroot', $d, @a ) }
sub gs_file  { "$_[0]/lazysite/auth/groups-settings.json" }
sub gs_read  { decode_json( slurp( gs_file( $_[0] ) ) ) }
sub had_file { "$_[0]/lazysite/auth/bundles-adopted.json" }

sub api {
    my ( $d, $p ) = @_;
    my $out = run_child( [ $^X, $tool, '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // { _raw => $out };
}

# The manager's own read: the ordinary use a site adopts a release on.
sub touch { api( $_[0], { action => 'users-page', me => 'boss' } ) }

sub groups_read {
    my ($d) = @_;
    my %g;
    for ( split /\n/, slurp("$d/lazysite/auth/groups") ) {
        next unless /^([^:]+):\s*(.*)$/;
        $g{$1} = [ sort grep { length } split /[,\s]+/, $2 ];
    }
    return \%g;
}

sub groups_write {
    my ( $d, $g ) = @_;
    spit( "$d/lazysite/auth/groups",
        join( '', map { "$_: " . join( ' ', @{ $g->{$_} } ) . "\n" } sort keys %$g ) );
}

sub seeded_site {
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    spit( "$d/lazysite/auth/users",    "boss:x\n" );
    cli( $d, 'setup-sysop', '--user', 'boss' );
    return $d;
}

my @ROLES   = qw(content-agent data-agent forms-reader analytics-agent);
my @BUNDLES = qw(cap-tidy cap-services ch-files);

# Take groups out of the store, as a release before them left it, and the
# record with them (an earlier release kept none).
sub remove_groups {
    my ( $d, @names ) = @_;
    my %gone = map { $_ => 1 } @names;
    my $gs = gs_read($d);
    delete @{$gs}{@names};
    spit( gs_file($d), encode_json($gs) );
    my $g = groups_read($d);
    delete @{$g}{@names};
    $_ = [ grep { !$gone{$_} } @$_ ] for values %$g;
    groups_write( $d, $g );
    unlink had_file($d);
}

# The store a site bootstrapped before SM608 has: no record carries the mark.
sub unmark {
    my ($d) = @_;
    my $gs = gs_read($d);
    delete $gs->{$_}{seeded} for grep { ref $gs->{$_} eq 'HASH' } keys %$gs;
    spit( gs_file($d), encode_json($gs) );
}

subtest 'a bootstrapped site the mark never reached adopts the roles and the bundles, once' => sub {
    my $d     = seeded_site();
    my $fresh = gs_read($d);
    my $nest  = groups_read($d);
    remove_groups( $d, @ROLES, @BUNDLES );
    unmark($d);
    my $gs = gs_read($d);
    ok( !( grep { $gs->{$_}{seeded} } keys %$gs ), 'no record carries `seeded`' );
    ok( $gs->{sysops} && $gs->{sysops}{manager}, '...and the manager group is there' );

    touch($d);
    my $after = gs_read($d);
    my $g     = groups_read($d);
    for my $role (@ROLES) {
        ok( ref $after->{$role} eq 'HASH', "$role is adopted" ) or next;
        my %want = %{ $fresh->{$role} };
        is_deeply( $after->{$role}, \%want, '...as shipped' );
    }
    unlike( slurp("$d/lazysite/auth/groups"), qr/^(?:content-agent|data-agent|forms-reader|analytics-agent):/m,
        'the roles have no members: nobody\'s access changes' );
    for my $b (@BUNDLES) {
        ok( ref $after->{$b} eq 'HASH', "$b is adopted" ) or next;
        my %want = %{ $fresh->{$b} };
        is_deeply( $after->{$b}, \%want,    '...as shipped' );
        is_deeply( $g->{$b},     $nest->{$b}, "...drawn on by the roles present: @{ $nest->{$b} }" );
    }
    is_deeply( $after->{'content-editors'}, $gs->{'content-editors'}, 'a role that was there is not rewritten' );
    ok( !$after->{sysops}{seeded}, 'nor is the manager group marked after the fact' );

    my $had = eval { decode_json( slurp( had_file($d) ) ) } || {};
    my %had = map { $_ => 1 } @{ $had->{bundles} || [] };
    ok( $had{$_}, "the record remembers $_" ) for @ROLES, @BUNDLES;

    my ( $store, $members ) = ( slurp( gs_file($d) ), slurp("$d/lazysite/auth/groups") );
    touch($d);
    is( slurp( gs_file($d) ),               $store,   'the next use of the tool changes nothing in the store' );
    is( slurp("$d/lazysite/auth/groups"),   $members, '...nor in the memberships' );
};

subtest 'a deleted role, and a deleted bundle, stay deleted' => sub {
    my $d = seeded_site();
    remove_groups( $d, @ROLES, @BUNDLES );
    unmark($d);
    touch($d);
    ok( gs_read($d)->{'forms-reader'} && gs_read($d)->{'cap-tidy'}, 'adopted' );
    api( $d, { action => 'group-delete', group => 'forms-reader' } );
    my $g = groups_read($d);
    $g->{'cap-tidy'} = [];
    groups_write( $d, $g );
    api( $d, { action => 'group-delete', group => 'cap-tidy' } );
    ok( !gs_read($d)->{'forms-reader'} && !gs_read($d)->{'cap-tidy'}, 'an operator deletes one of each' );
    touch($d);
    ok( !gs_read($d)->{'forms-reader'}, 'the role does not come back' );
    ok( !gs_read($d)->{'cap-tidy'},     'nor does the bundle' );
};

subtest 'a record that cannot be read adopts nothing' => sub {
    my $d = seeded_site();
    remove_groups( $d, @ROLES, @BUNDLES );
    unmark($d);
    spit( had_file($d), 'not json' );
    touch($d);
    ok( !gs_read($d)->{'content-agent'} && !gs_read($d)->{'cap-tidy'}, 'nothing is adopted' );
    is( slurp( had_file($d) ), 'not json', '...and the record is not written over' );
};

subtest 'on a store the mark reached, an unmarked group under a shipped name is still an operator\'s' => sub {
    my $d = seeded_site();
    remove_groups( $d, qw(analysts cap-audit) );
    # an operator's own group, made under the shipped name, on a marked store
    api( $d, { action => 'group-create', group => 'analysts' } );
    ok( gs_read($d)->{analysts} && !gs_read($d)->{analysts}{seeded}, 'the operator\'s analysts group is unmarked' );
    ok( gs_read($d)->{sysops}{seeded}, '...on a store whose manager group carries the mark' );
    touch($d);
    ok( !gs_read($d)->{'cap-audit'}, 'cap-audit, drawn on by analysts alone, is not nested into the operator\'s group' );
};

subtest 'a site with a manager group and no role layer gets the roles and no bundle' => sub {
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    spit( "$d/lazysite/auth/users",    "boss:x\n" );
    spit( "$d/lazysite/auth/groups",   "admins: boss\n" );
    spit( gs_file($d), encode_json( { admins => { label => 'Admins', manager => 1, assignable => 1, ui => 1, manage_users => 1 } } ) );
    touch($d);
    my $gs = gs_read($d);
    ok( $gs->{$_}, "$_ is adopted" ) for @ROLES;
    ok( !( grep { /^(?:cap|ch)-/ } keys %$gs ), 'no bundle is invented on a site without the bundle layer' );
    ok( !$gs->{'content-editors'}, 'and no role of the old layer either' );
};

subtest 'a store with no manager group adopts nothing' => sub {
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    spit( "$d/lazysite/auth/users",    "boss:x\n" );
    spit( gs_file($d), encode_json( { eds => { label => 'Eds', assignable => 1, manage_content => 1 } } ) );
    touch($d);
    ok( !gs_read($d)->{'content-agent'}, 'not bootstrapped: no role is adopted' );
};

done_testing;
