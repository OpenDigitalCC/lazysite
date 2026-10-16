#!/usr/bin/perl
# SM1095: a token naming no scope was refused a domain with "A domain-confined
# caller reaches only the domains whose content lies inside no scope: (default)".
# That is the SM976 rule, but to an account whose brief says "Content scope:
# whole docroot" it reads as nonsense. The refusal now says what is true of that
# caller; a caller that has scopes still gets the confined-caller wording.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root setup_multi_domain_site);
use lib repo_root() . '/lib';
use Lazysite::Manager::Common qw(domain_reach_refusal reset_request_context
    $token_auth %token_caps @REQUEST_SCOPES $REQUEST_CONFINED $IS_OPERATOR);
use Lazysite::Manager::Domains ();

my $s = setup_multi_domain_site( extra_conf => "alias_hosts: alpha.test, beta.test, sub.alpha.test, mirror.test\n" );
$Lazysite::Manager::Common::DOCROOT  = $s->{docroot};
$Lazysite::Manager::Domains::DOCROOT = $s->{docroot};

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

as( token => 1, confined => 1 );
my $r = domain_reach_refusal( host => 'alpha.test' );
is( $r->{kind}, 'forbidden', 'an unscoped token is refused a domain with a root of its own' );
unlike( $r->{error}, qr/inside no scope/, 'the refusal does not format an empty scope list' );
unlike( $r->{error}, qr/domain-confined caller/, 'nor call a caller with no scope confined' );
like( $r->{error}, qr/not confined to a domain's content/, 'it says the caller is not confined to a domain' );
like( $r->{error}, qr/default domain/, 'and that it reaches the default domain' );
like( $r->{error}, qr/alpha\.test/, 'and still names the domain refused' );
like( $r->{error}, qr/mirror\.test/, 'and the domains it does reach' );

as( token => 1, confined => 1, scopes => ['sites/alpha'] );
$r = domain_reach_refusal( host => 'beta.test' );
like( $r->{error}, qr/A domain-confined caller reaches only the domains whose content lies inside its scope \(sites\/alpha\/\)/,
    'a caller with a scope keeps the confined-caller wording' );

done_testing();
