#!/usr/bin/perl
# n785 (T-112, the 0.16.8 edge results): `analysts` and `lead-readers` did not
# arrive on edge after the Groups page was opened.
#
# The cause is the trigger, not the store. The adoptions (SM1241, SM1371, SM1407)
# run in _ensure_groups_seeded, which the Users page's read (users-page) calls
# and the Groups page's read (group-settings-get) did not. So a store
# bootstrapped before 0.16.0 and upgraded through 0.16.8 - no `seeded` mark on
# its manager group (SM1393), the bundle layer there, a had-record from the
# earlier adoptions naming the bundles and the agent roles but not these two -
# kept lacking them however often the Groups page was opened. Held here:
#
#   * on such a store, the Groups page's read adopts both, as shipped, with no
#     members, nested into their bundles;
#   * once: an operator who deletes them keeps them deleted, page after page;
#   * the groups listing (Manager::Groups::groups_list, MCP list_groups and the
#     control API's `groups`) shows whether the operator group carries the mark.
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
my @ROLES = qw(analysts lead-readers);

sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; $t }
sub spit  { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub gs_file  { "$_[0]/lazysite/auth/groups-settings.json" }
sub gs_read  { decode_json( slurp( gs_file( $_[0] ) ) ) }
sub had_file { "$_[0]/lazysite/auth/bundles-adopted.json" }

sub api {
    my ( $d, $p ) = @_;
    my $out = run_child( [ $^X, $tool, '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'discard' )->{out};
    return eval { decode_json($out) } // { _raw => $out };
}

# The Groups page's read, as the manager asks it.
sub groups_page { api( $_[0], { action => 'group-settings-get', me => 'boss' } ) }

sub members {
    my ($d) = @_;
    my %g;
    for ( split /\n/, slurp("$d/lazysite/auth/groups") ) {
        $g{$1} = [ sort grep { length } split /[,\s]+/, $2 ] if /^([^:]+):\s*(.*)$/;
    }
    return \%g;
}

sub fresh_site {
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    spit( "$d/lazysite/auth/users",    "boss:x\n" );
    run_cmd( $^X, $tool, '--docroot', $d, 'setup-sysop', '--user', 'boss' );
    return $d;
}

# A store bootstrapped before 0.16.0 and upgraded through 0.16.8: no record
# carries the mark (SM1393's edge store), the two roles and cap-audit (drawn on
# by analysts alone) were never written, and the had-record the 0.16.5-0.16.7
# adoptions left names every other group.
sub upgraded_store {
    my $d  = fresh_site();
    my $gs = gs_read($d);
    my %gone = map { $_ => 1 } @ROLES, 'cap-audit';
    delete @{$gs}{ keys %gone };
    delete $gs->{$_}{seeded} for grep { ref $gs->{$_} eq 'HASH' } keys %$gs;
    spit( gs_file($d), encode_json($gs) );
    my $m = members($d);
    delete @{$m}{ keys %gone };
    $_ = [ grep { !$gone{$_} } @$_ ] for values %$m;
    spit( "$d/lazysite/auth/groups", join( '', map { "$_: @{ $m->{$_} }\n" } sort keys %$m ) );
    spit( had_file($d), encode_json( { bundles => [ sort keys %$gs ] } ) );
    return $d;
}

subtest 'the Groups page adopts the layer roles on an upgraded store' => sub {
    my $fresh = gs_read( fresh_site() );
    my $d     = upgraded_store();
    ok( !gs_read($d)->{$_}, "$_ is absent before" ) for @ROLES;
    my $r = groups_page($d);
    ok( $r->{ok}, 'the Groups page reads' ) or diag explain $r;
    my $gs = gs_read($d);
    my $m  = members($d);
    for my $role (@ROLES) {
        ok( ref $gs->{$role} eq 'HASH', "$role is adopted" ) or next;
        is_deeply( $gs->{$role}, $fresh->{$role}, '...as shipped' );
        ok( !$m->{$role}, '...with no members' );
        ok( $r->{groups}{$role}, '...and the page that adopted it lists it' );
    }
    ok( ( grep { $_ eq 'analysts' } @{ $m->{'cap-analytics'} || [] } ), 'analysts is nested in cap-analytics' );
    ok( ( grep { $_ eq 'lead-readers' } @{ $m->{'ch-script'} || [] } ), 'lead-readers is nested in ch-script' );
};

subtest 'once: a deleted role stays deleted' => sub {
    my $d = upgraded_store();
    groups_page($d);
    my $m = members($d);
    $_ = [ grep { $_ ne 'analysts' && $_ ne 'lead-readers' } @$_ ] for values %$m;
    spit( "$d/lazysite/auth/groups", join( '', map { "$_: @{ $m->{$_} }\n" } sort keys %$m ) );
    for my $role (@ROLES) {
        my $del = api( $d, { action => 'group-delete', group => $role } );
        ok( !gs_read($d)->{$role}, "the operator deletes $role" ) or diag explain $del;
    }
    groups_page($d);
    groups_page($d);
    api( $d, { action => 'users-page', me => 'boss' } );
    ok( !gs_read($d)->{$_}, "$_ does not come back" ) for @ROLES;
};

subtest 'the groups listing shows whether the operator group carries the mark' => sub {
    require Lazysite::Manager::Groups;
    require Lazysite::Auth::Acl;
    no warnings 'once';
    for my $case ( [ 'a fresh site', fresh_site(), 1 ], [ 'the upgraded store', upgraded_store(), 0 ] ) {
        my ( $what, $d, $want ) = @$case;
        local $Lazysite::Auth::Acl::DOCROOT = $d;
        my $l = Lazysite::Manager::Groups::groups_list( actor => 'boss' );
        my ($op) = grep { $_->{operator} } @{ $l->{groups} || [] };
        ok( $op, "$what: the operator group is listed" ) or next;
        ok( exists $op->{seeded}, '...with its seeded mark shown' );
        is( ( $op->{seeded} ? 1 : 0 ), $want, "...$what: " . ( $want ? 'marked' : 'not marked' ) );
    }
};

done_testing;
