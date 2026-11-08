#!/usr/bin/perl
# SM1407: `analysts` AND `lead-readers` REACH A SITE BOOTSTRAPPED BEFORE THEY
# SHIPPED, ONCE.
#
# The two roles shipped with the bundle layer (SM631, 0.11.2) in the seed only.
# _adopt_added_bundles adopts the bundles the nesting map lists and
# _adopt_agent_roles the four agent roles, so on the 0.16.7 edge site the
# agent roles arrived and these two never did (T-103). They are now adopted the
# way the agent roles are - a bootstrapped site, an absent role only, no
# members, once by the had-record (SM1262) - where the bundle layer is there,
# nested into its bundles as a new install nests them, and never on a store the
# `seeded` mark reached: the mark (0.11.3) came after them, so absent there is
# an operator's delete.
#
# In the style of t/unit/users/72. With the change reverted: the first
# subtest's two roles stay absent.
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
sub had_read { my $h = eval { decode_json( slurp( had_file( $_[0] ) ) ) } || {}; +{ map { $_ => 1 } @{ $h->{bundles} || [] } } }

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

my @ROLES = qw(analysts lead-readers);

# The store a release before the two roles left: neither role, nor cap-audit
# (which only analysts draws on), nor a record of them.
sub before_the_roles {
    my ( $d, %o ) = @_;
    my @names = ( @ROLES, 'cap-audit' );
    my %gone  = map { $_ => 1 } @names;
    my $gs    = gs_read($d);
    delete @{$gs}{@names};
    unless ( $o{marked} ) {
        delete $gs->{$_}{seeded} for grep { ref $gs->{$_} eq 'HASH' } keys %$gs;
    }
    spit( gs_file($d), encode_json($gs) );
    my $g = groups_read($d);
    delete @{$g}{@names};
    $_ = [ grep { !$gone{$_} } @$_ ] for values %$g;
    groups_write( $d, $g );
    unlink had_file($d);
}

subtest 'a store from before the two roles gains both on first use, once' => sub {
    my $d     = seeded_site();
    my $fresh = gs_read($d);
    my $nest  = groups_read($d);
    before_the_roles($d);
    ok( !gs_read($d)->{$_}, "$_ is absent" ) for @ROLES;

    touch($d);
    my $after = gs_read($d);
    my $g     = groups_read($d);
    for my $role (@ROLES) {
        ok( ref $after->{$role} eq 'HASH', "$role is adopted" ) or next;
        is_deeply( $after->{$role}, $fresh->{$role}, '...as shipped' );
        ok( !$g->{$role}, '...with no members: nobody\'s access changes' );
    }
    for my $b (qw(cap-analytics cap-audit ch-ui ch-script)) {
        is_deeply( $g->{$b}, $nest->{$b}, "$b draws on the roles a new install nests in it: @{ $nest->{$b} }" );
    }
    ok( ref $after->{'cap-audit'} eq 'HASH', 'cap-audit, drawn on by analysts alone, is adopted with it' );
    my $had = had_read($d);
    ok( $had->{$_}, "the record remembers $_" ) for @ROLES;

    my ( $store, $members ) = ( slurp( gs_file($d) ), slurp("$d/lazysite/auth/groups") );
    touch($d);
    is( slurp( gs_file($d) ),             $store,   'the next use of the tool changes nothing in the store' );
    is( slurp("$d/lazysite/auth/groups"), $members, '...nor in the memberships' );
};

subtest 'a role the had-record names does not come back' => sub {
    my $d = seeded_site();
    before_the_roles($d);
    spit( had_file($d), encode_json( { bundles => ['lead-readers'] } ) );
    touch($d);
    ok( gs_read($d)->{analysts},        'analysts, not in the record, is adopted' );
    ok( !gs_read($d)->{'lead-readers'}, 'lead-readers, in the record, is not' );

    my $g = groups_read($d);
    $_ = [ grep { $_ ne 'analysts' } @$_ ] for values %$g;
    groups_write( $d, $g );
    api( $d, { action => 'group-delete', group => 'analysts' } );
    ok( !gs_read($d)->{analysts}, 'an operator deletes analysts' );
    touch($d);
    ok( !gs_read($d)->{analysts}, '...and it does not come back' );
};

subtest 'on a store the mark reached, an absent role was deleted and stays so' => sub {
    my $d = seeded_site();
    before_the_roles( $d, marked => 1 );
    ok( gs_read($d)->{sysops}{seeded}, 'the manager group carries the mark' );
    touch($d);
    ok( !gs_read($d)->{$_}, "$_ is not adopted" ) for @ROLES;
    my $had = had_read($d);
    ok( $had->{$_}, "...and the record keeps $_ as had" ) for @ROLES;
};

subtest 'a site without the bundle layer gets neither' => sub {
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    spit( "$d/lazysite/auth/users",    "boss:x\n" );
    spit( "$d/lazysite/auth/groups",   "admins: boss\n" );
    spit( gs_file($d), encode_json( { admins => { label => 'Admins', manager => 1, assignable => 1, ui => 1, manage_users => 1 } } ) );
    touch($d);
    ok( !gs_read($d)->{$_}, "$_ is not adopted: it would grant nothing there" ) for @ROLES;
    ok( gs_read($d)->{'content-agent'}, 'while the agent roles, which need no bundle, are' );
};

done_testing;
