#!/usr/bin/perl
# SM1332 (ruling 78): A GRANT ON THE PRIMARY'S ROW REACHES THE PRIMARY, AND
# KEEPS THE OTHER DOMAINS IT IS GRANTED - on the one domain rule every surface
# asks (Lazysite::Manager::Common::caller_may_reach_domain), the rules built on
# it (served themes, content paths, instance-wide writes), and the refusal a
# caller is shown.
#
# The scope a primary grant adds is the docroot (DomainAccess::PRIMARY_SCOPE).
# By path that contains every domain's content, so the domain rule must read it
# as the primary only - the table below holds that beta, which the caller is
# not granted, stays out of reach.
#
# The instance: alpha.test at sites/alpha, beta.test at sites/beta,
# sub.alpha.test at sites/alpha/inner, mirror.test with no content root (it
# serves the primary's content), and the primary on layout base, theme base.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root setup_multi_domain_site);
use lib repo_root() . '/lib';
use Lazysite::Manager::Common qw(caller_may_reach_domain reachable_domains domain_reach_refusal
    served_artifact_refusal caller_may_reach_path reset_request_context
    $token_auth %token_caps @REQUEST_SCOPES $REQUEST_CONFINED $IS_OPERATOR);
use Lazysite::Manager::Domains ();
use Lazysite::Auth::DomainAccess qw(PRIMARY_SCOPE);

my $s = setup_multi_domain_site( extra_conf => "alias_hosts: alpha.test, beta.test, sub.alpha.test, mirror.test\n" );
$Lazysite::Manager::Common::DOCROOT  = $s->{docroot};
$Lazysite::Manager::Domains::DOCROOT = $s->{docroot};
my $P = PRIMARY_SCOPE;

my @TARGETS = (
    [ host => 'alpha.test' ],       [ host => 'beta.test' ], [ host => 'sub.alpha.test' ],
    [ host => 'mirror.test' ],      [ host => '' ],          [ host => '(default)' ],
    [ host => 'unserved.example' ], [ root => 'sites/alpha/new' ], [ root => 'sites/else' ],
    [ root => '' ],
);
sub label { my ( $k, $v ) = @_; return "$k " . ( length $v ? $v : "''" ) }

sub as {
    my (%c) = @_;
    reset_request_context();
    $token_auth       = $c{token} ? 1 : 0;
    @REQUEST_SCOPES   = @{ $c{scopes} || [] };
    %token_caps       = ( dav_scopes => [ @{ $c{scopes} || [] } ] );
    $REQUEST_CONFINED = $c{confined} ? 1 : 0;
    $IS_OPERATOR      = 0;
    return;
}

#            alpha beta sub mirror '' (default) unserved new else root''
my %TABLE = (
    'a token scoped to alpha (today: no primary)' => [ { token => 1, confined => 1, scopes => ['sites/alpha'] }, 'YNYNNNNYNN' ],
    'a token granted alpha and the primary row' => [ { token => 1, confined => 1, scopes => [ $P, 'sites/alpha' ] }, 'YNYYYYNYNY' ],
    'a token granted the primary row only' => [ { token => 1, confined => 1, scopes => [$P] }, 'NNNYYYNNNY' ],
    'a cookie manager granted alpha and the primary' => [ { confined => 1, scopes => [ $P, 'sites/alpha' ] }, 'YNYYYYNYNY' ],
    'a token naming no scope (unbound, as before)' => [ { token => 1, confined => 1 }, 'NNNYYYNNNY' ],
);
for my $who ( sort keys %TABLE ) {
    my ( $ctx, $want ) = @{ $TABLE{$who} };
    as(%$ctx);
    my @w = split //, $want;
    for my $i ( 0 .. $#TARGETS ) {
        my $got = caller_may_reach_domain( @{ $TARGETS[$i] } ) ? 'Y' : 'N';
        is( $got, $w[$i], "$who: " . label( @{ $TARGETS[$i] } ) );
    }
}

subtest 'the grant form MCP and WebDAV pass, and the listing' => sub {
    as();
    is_deeply( [ reachable_domains( scopes => [ $P, 'sites/alpha' ] ) ],
        [ '(default)', 'alpha.test', 'sub.alpha.test', 'mirror.test' ], 'the primary, its mirror, and alpha' );
    is_deeply( [ reachable_domains( scopes => ['sites/alpha'] ) ], [ 'alpha.test', 'sub.alpha.test' ],
        'without the primary grant: alpha only, as before' );
    ok( caller_may_reach_domain( scopes => ['//'], host => '' ), 'the docroot however it is spelt' );
};

subtest 'the primary grant is the primary content, whole, as for an unbound caller' => sub {
    my @who = ( scopes => [ $P, 'sites/alpha' ] );
    ok( caller_may_reach_path( 'about.md', @who ),   'a primary page' );
    ok( caller_may_reach_path( '',         @who ),   'the site root' );
    ok( caller_may_reach_path( 'sites/alpha/x.md', @who ), 'its own domain' );
    ok( !caller_may_reach_path( 'about.md', scopes => ['sites/alpha'] ), 'without it: not a primary page' );
};

subtest 'instance-wide writes follow the primary' => sub {
    ok( !Lazysite::Manager::Common::caller_is_confined( scopes => [ $P, 'sites/alpha' ] ),
        'granted the primary: not confined, as the unbound caller is not' );
    ok( Lazysite::Manager::Common::caller_is_confined( scopes => ['sites/alpha'] ), 'scoped to alpha only: confined' );
};

subtest 'a theme the primary serves' => sub {
    my $css = 'lazysite/layouts/base/themes/base/x.css';
    my ( $err, $detail ) = served_artifact_refusal( $css, scopes => ['sites/alpha'] );
    like( $err, qr/served by a site you do not reach/, 'scoped to alpha: refused, as before' );
    like( $err, qr/primary is granted on its own row.*\(default\) domain's allowed_groups/,
        '...naming where the primary is granted' );
    # beta.test and sub.alpha.test inherit the primary's theme, so they serve it too.
    ok( served_artifact_refusal( $css, scopes => [ $P, 'sites/alpha' ] ), 'granted the primary and alpha: beta serves it too, refused' );
    ok( !served_artifact_refusal( $css, scopes => [ $P, 'sites/alpha', 'sites/beta' ] ),
        'granted every site that serves it, the primary among them: allowed' );
    ok( served_artifact_refusal( $css, scopes => [ 'sites/alpha', 'sites/beta' ] ), '...and without the primary: refused' );
    my ($e2) = served_artifact_refusal( 'lazysite/layouts/alpha-layout/themes/alpha-theme/x.css', scopes => [$P] );
    like( $e2, qr/served by a site you do not reach/, 'the primary grant does not reach alpha\'s theme' );
    unlike( $e2, qr/primary is granted/, '...and does not send it to the primary row' );
};

subtest 'the refusal names the primary row' => sub {
    as( token => 1, confined => 1, scopes => ['sites/alpha'] );
    my $r = domain_reach_refusal( host => '(default)' );
    is( $r->{kind}, 'forbidden', 'the primary is refused to a token scoped to alpha' );
    like( $r->{error}, qr/You cannot reach the primary site\. A domain-confined caller reaches only the domains it is granted/,
        'says what it reaches' );
    like( $r->{error}, qr/The primary site is granted on its own row.*\(default\) domain's allowed_groups \(Domains page\)/,
        'and where the primary is granted' );
    my $b = domain_reach_refusal( host => 'beta.test' );
    unlike( $b->{error}, qr/granted on its own row/, 'a secondary domain\'s refusal does not point at the primary row' );
    as( token => 1, confined => 1, scopes => [ $P, 'sites/alpha' ] );
    like( domain_reach_refusal( host => 'beta.test' )->{error}, qr/its scope \(the primary site, sites\/alpha\/\)/,
        'the primary grant is named as the primary, not as a folder' );
    is( domain_reach_refusal( host => '' ), undef, 'and the primary is not refused' );
};

done_testing();
