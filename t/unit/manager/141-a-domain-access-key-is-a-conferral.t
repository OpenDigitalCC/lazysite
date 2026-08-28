#!/usr/bin/perl
# SM647: `domain-set` wrote a domain's access model with neither authority over
# groups nor regard for the caller's own content scope.
#
# MEASURED, not inferred. The site agent proved both halves on edge 0.11.3 with
# a credential holding manage_domains and NOT manage_users, scoped to
# sites/edge3:
#   * it rewrote allowed_groups on a domain OUTSIDE that scope    -> ok:true
#   * it named a group it had no authority over                   -> ok:true
# Harmless instrument throughout: a non-existent group, a throwaway domain, both
# reverted and verified. SM195's ceiling governs conferral in the users tool and
# never reached this path; allowed_groups was validated for SHAPE only.
#
# Release manager's decision: both halves close. allowed_groups and locked_users
# need manage_users as well; every key is scope-checked against the domain's
# content root.
#
# THE POSITIVE DIRECTION IS ASSERTED FIRST AND MATTERS MORE. A gate that refuses
# everything closes both holes and breaks domain management, and would be
# reported as an outage rather than as a fix.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);

plan skip_all => 'manager api missing' unless -f repo_root() . '/lazysite-manager-api.pl';

my @ALL = qw(ui manage_domains manage_users manage_config manage_content);
my $s   = new_site( root => repo_root() );
$s->add_user('dm');
sub hold { $s->grant( 'dm', 'domainfolk', [ 'ui', @_ ], \@ALL ) }

# Two domains: one the caller will be scoped to, one it will not.
hold( 'manage_domains', 'manage_users' );
for my $d ( [ 'mine.example.org', 'sites/mine' ], [ 'other.example.org', 'sites/other' ] ) {
    my $r = $s->call( 'dm', 'domain-add',
        body => { host => $d->[0], content_root => $d->[1],
            site_url => "https://$d->[0]", site_name => $d->[0] } );
    ok( $r->{ok}, "set up $d->[0]" ) or diag( $r->{error} // '' );
}

subtest 'an unscoped holder of both may still set an access key' => sub {
    my $r = $s->call( 'dm', 'domain-set',
        body => { host => 'mine.example.org', key => 'allowed_groups', value => 'editors' } );
    ok( $r->{ok}, 'allowed_groups is settable with manage_domains + manage_users' )
        or diag( 'got: ' . ( $r->{error} // '' ) );
};

subtest 'a non-access key still needs only manage_domains' => sub {
    hold('manage_domains');
    my $r = $s->call( 'dm', 'domain-set',
        body => { host => 'mine.example.org', key => 'site_name', value => 'Renamed' } );
    ok( $r->{ok}, 'site_name is unaffected by the new rule' )
        or diag( 'got: ' . ( $r->{error} // '' ) );
};

subtest 'the conferral ceiling: an access key needs manage_users' => sub {
    hold('manage_domains');    # deliberately WITHOUT manage_users
    for my $key (qw(allowed_groups locked_users)) {
        my $r = $s->call( 'dm', 'domain-set',
            body => { host => 'mine.example.org', key => $key, value => 'anygroup' } );
        ok( !$r->{ok}, "$key is refused without manage_users" )
            or diag( 'This is the measured hole: a domain manager conferring a '
                . 'group it has no authority over.' );
        is( $r->{kind} // '', 'forbidden', "$key refuses as a capability matter" );
        like( $r->{error} // '', qr/Users & groups/,
            "$key names the capability that is missing" );
    }
};

subtest 'the scope guard: a domain outside the caller\'s reach is refused' => sub {
    # A SCOPE IS NOT AN ACCOUNT FIELD. It is derived: a domain names groups in
    # allowed_groups, and a member of one of those groups is confined to that
    # domain's content root.
    #
    # AND THE CALLER MUST NOT HOLD manage_users. _is_operator() treats that
    # capability as operator, and an operator is unconfined by construction - so
    # a caller holding it is never scope-checked. The first version of this
    # subtest granted manage_users to satisfy the conferral rule and then
    # wondered why no scope applied.
    #
    # That interaction is worth stating plainly: since an access key now
    # REQUIRES manage_users, and manage_users makes a caller an operator,
    # anybody who can write allowed_groups is unconfined. The scope guard
    # therefore binds the remaining keys, for a scoped manage_domains holder -
    # which is the credential the escape was measured with.
    my $setup = 'boss';
    $s->add_user($setup);
    $s->grant( $setup, 'bosses', [ 'ui', 'manage_domains', 'manage_users' ], \@ALL );
    my $r = $s->call( $setup, 'domain-set',
        body => { host => 'mine.example.org', key => 'allowed_groups', value => 'domainfolk' } );
    ok( $r->{ok}, 'an operator confines dm by naming its group on one domain' )
        or diag( 'got: ' . ( $r->{error} // '' ) );

    hold('manage_domains');    # scoped, and NOT an operator

    my $inside = $s->call( 'dm', 'domain-set',
        body => { host => 'mine.example.org', key => 'site_name', value => 'Still Mine' } );
    ok( $inside->{ok}, 'it may still manage the domain it is scoped to' )
        or diag( 'The direction that would be reported as an outage: '
            . ( $inside->{error} // '' ) );

    my $outside = $s->call( 'dm', 'domain-set',
        body => { host => 'other.example.org', key => 'site_name', value => 'Grabbed' } );
    ok( !$outside->{ok}, 'and a domain outside its scope is refused' )
        or diag( 'This is the measured escape: a scoped domain manager '
            . "reaching another domain's row." );
    like( $outside->{error} // '', qr/outside your assigned scope/,
        'the refusal says why' );
    like( $outside->{error} // '', qr{sites/other},
        'naming the content root that put it out of reach' );
};

done_testing();
