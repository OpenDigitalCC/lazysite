#!/usr/bin/perl
# SM802: who may say where a domain's visitors are sent.
#
# Ruled operator-only: a rule sends a visitor to another host, the same class of
# authority as a connector's destination. Granted as manage_domains, because the
# ruling calls this domain configuration, and PER HOST, so a save replaces one
# domain's rules and never another's.
#
# THE SCOPE CHECK IS STRICTER THAN domain-set's, and this file is why. SM647
# measured a scoped manage_domains holder reaching another domain's row, and
# domain-set now refuses a host whose content root is outside the caller's
# scope - but it lets through a host with NO content root. For a redirect that
# is still a reach: the instance answers for its own hostname and for any
# unregistered host pointed at it, so a scoped caller naming one could send
# someone else's visitors anywhere. Here a scoped caller may name only a
# REGISTERED domain inside its scope.
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
$s->add_user('boss');
$s->grant( 'boss', 'bosses', [qw(ui manage_domains manage_users manage_config)], \@ALL );
$s->add_user('dm');
sub hold { $s->grant( 'dm', 'domainfolk', [ 'ui', @_ ], \@ALL ) }

for my $d ( [ 'mine.example.org', 'sites/mine' ], [ 'other.example.org', 'sites/other' ] ) {
    my $r = $s->call( 'boss', 'domain-add',
        body => { host => $d->[0], content_root => $d->[1],
            site_url => "https://$d->[0]", site_name => $d->[0] } );
    ok( $r->{ok}, "set up $d->[0]" ) or diag( $r->{error} // '' );
}
my $rule = [ { prefix => '/web', destination => 'https://backend.example.com' } ];

# --- switched off, it refuses and says how to turn it on --------------------
{
    my $r = $s->call( 'boss', 'remap-save', body => { host => 'other.example.org', rules => $rule } );
    ok( !$r->{ok}, 'with the extension off, a save is refused' );
    is( $r->{kind} // '', 'disabled', '...as switched off, not as forbidden' );
    like( $r->{error} // '', qr/Extension Manager/, '...naming where it is turned on' );
}

# Switch it on the way an operator would.
{
    open my $cf, '>>', $s->docroot . '/lazysite/lazysite.conf' or die $!;
    print {$cf} "extensions:\n  - plugins/remap.pl\n";
    close $cf;
}

# --- an unscoped operator ---------------------------------------------------
{
    my $r = $s->call( 'boss', 'remap-save', body => { host => 'other.example.org', rules => $rule } );
    ok( $r->{ok}, 'an unscoped manage_domains holder sets a domain\'s rules' ) or diag( $r->{error} // '' );
    my $l = $s->call( 'boss', 'remap-list' );
    ok( ( grep { $_->{host} eq 'other.example.org' && $_->{prefix} eq '/web' } @{ $l->{rules} || [] } ),
        '...and they are listed back' );
}

# --- a scoped domain manager ------------------------------------------------
{
    my $r = $s->call( 'boss', 'domain-set',
        body => { host => 'mine.example.org', key => 'allowed_groups', value => 'domainfolk' } );
    ok( $r->{ok}, 'an operator confines dm to one domain by naming its group' ) or diag( $r->{error} // '' );
}
hold('manage_domains');    # scoped, and NOT an operator (manage_users would unconfine it)
{
    my $in = $s->call( 'dm', 'remap-save', body => { host => 'mine.example.org', rules => $rule } );
    ok( $in->{ok}, 'a scoped manager sets rules for the domain it is scoped to' ) or diag( $in->{error} // '' );

    my $out = $s->call( 'dm', 'remap-save', body => { host => 'other.example.org', rules => [] } );
    ok( !$out->{ok}, 'but not for a domain outside its scope - not even to clear them' );
    is( $out->{kind} // '', 'forbidden', '...refused as a matter of reach' );

    my $un = $s->call( 'dm', 'remap-save', body => { host => 'unregistered.example.net', rules => $rule } );
    ok( !$un->{ok}, 'and not for an UNREGISTERED host - the reach domain-set leaves open' )
        or diag 'the instance answers for hosts pointed at it; a rule here redirects visitors it does not own';

    my $l = $s->call( 'dm', 'remap-list' );
    my @hosts = map { $_->{host} } @{ $l->{rules} || [] };
    ok( !( grep { $_ eq 'other.example.org' } @hosts ), 'the listing shows it no other domain\'s rules' );
    ok( ( grep { $_ eq 'mine.example.org' } @hosts ),   '...and does show its own' );
}

# --- other.example.org's rule survived the scoped caller's saves ------------
{
    my $l = $s->call( 'boss', 'remap-list' );
    ok( ( grep { $_->{host} eq 'other.example.org' } @{ $l->{rules} || [] } ),
        'a save for one domain left another domain\'s rules alone' );
}

# --- without the capability -------------------------------------------------
hold('manage_content');
{
    my $r = $s->call( 'dm', 'remap-save', body => { host => 'mine.example.org', rules => $rule } );
    ok( !$r->{ok}, 'an author cannot write a redirect rule - operator-only, by ruling' );
}

done_testing();
