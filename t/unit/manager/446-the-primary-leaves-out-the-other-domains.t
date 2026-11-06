#!/usr/bin/perl
# SM1372 (ruling 126): THE PRIMARY'S CONTENT LEAVES OUT THE OTHER DOMAINS' ROOTS,
# on the content-path rule the manager API, MCP and the file actions ask
# (Lazysite::Manager::Common::outside_all_scopes, caller_may_reach_path) and in
# the resolver's own rule (Lazysite::Auth::DomainAccess::foreign_root_of).
#
# An unbound caller's empty scope list and the primary's grant each read as the
# whole docroot, which by path holds every secondary domain's content root. Now a
# confined caller reaching the primary does not reach a domain's root it is not
# granted; one granted that domain keeps it; the unconfined operator (the cookie
# operator, $REQUEST_CONFINED 0) keeps the whole. WebDAV: t/unit/dav/39.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root setup_multi_domain_site);
use lib repo_root() . '/lib';
use Lazysite::Manager::Common qw(caller_may_reach_path reset_request_context
    $token_auth %token_caps @REQUEST_SCOPES $REQUEST_CONFINED $IS_OPERATOR);
use Lazysite::Auth::DomainAccess qw(PRIMARY_SCOPE read_domains foreign_root_of);

my $s = setup_multi_domain_site( extra_conf => "alias_hosts: alpha.test, beta.test, mirror.test\n" );
$Lazysite::Manager::Common::DOCROOT = $s->{docroot};
my $P   = PRIMARY_SCOPE;
my $dom = read_domains("$s->{docroot}/lazysite/lazysite.conf");

subtest 'the rule: which root a path lies in, for which scopes' => sub {
    ( my $beta = $dom->{'beta.test'}{content_root} // '' ) =~ s{^/+|/+$}{}g;
    ok( length $beta, "the fixture roots beta.test at $beta" ) or return;
    is( foreign_root_of( $dom, [], "$beta/x.md" ), $beta, 'unbound: another domain\'s page is foreign' );
    is( foreign_root_of( $dom, [$P], "/$beta/" ), $beta, 'the primary grant: so is its folder' );
    is( foreign_root_of( $dom, [$P], 'about.md' ), undef, 'a primary page is not' );
    is( foreign_root_of( $dom, [ $P, $beta ], "$beta/x.md" ), undef, 'granted beta as well: beta is its own' );
    is( foreign_root_of( $dom, [$beta], "$beta/x.md" ), undef, 'a list not reaching the docroot is its own roots\' business' );
    is( foreign_root_of( $dom, [], "${beta}x/y.md" ), undef, 'a sibling folder whose name begins the same is not inside' );
};

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

my ( $alpha, $beta ) = map { ( my $x = $dom->{$_}{content_root} // '' ) =~ s{^/+|/+$}{}g; $x } qw(alpha.test beta.test);

subtest 'the doors: unbound and primary-granted callers, a granted domain, the operator' => sub {
    for my $c (
        [ 'a token naming no scope',         { token => 1, confined => 1 } ],
        [ 'a token granted the primary row', { token => 1, confined => 1, scopes => [$P] } ],
        [ 'a cookie manager granted nothing', { confined => 1 } ],
        )
    {
        my ( $label, $who ) = @$c;
        as(%$who);
        ok( !Lazysite::Manager::Common::outside_all_scopes( \@REQUEST_SCOPES, 'about.md' ), "$label: a primary page" );
        ok( Lazysite::Manager::Common::outside_all_scopes( \@REQUEST_SCOPES, "$beta/x.md" ),
            "$label: not another domain's page" );
        ok( !caller_may_reach_path("$beta/x.md"), "$label: caller_may_reach_path agrees" );
    }

    as( token => 1, confined => 1, scopes => [ $P, $alpha ] );
    ok( !Lazysite::Manager::Common::outside_all_scopes( \@REQUEST_SCOPES, "$alpha/x.md" ), 'granted alpha too: alpha' );
    ok( Lazysite::Manager::Common::outside_all_scopes( \@REQUEST_SCOPES, "$beta/x.md" ), '  and still not beta' );

    as( confined => 0 );
    ok( !Lazysite::Manager::Common::outside_all_scopes( [], "$beta/x.md" ), 'the cookie operator reaches beta' );
    ok( caller_may_reach_path("$beta/x.md"), '  and caller_may_reach_path agrees' );
};

# Ruling 137: the manager's file browser (action_list, which MCP list_files also
# answers through) leaves out the domains' folders a caller is refused, where
# ruling 126 left their names showing. The operator and a granted domain see them.
subtest 'the file browser leaves out the folders the caller is refused (ruling 137)' => sub {
    require Lazysite::Manager::Files;
    local $Lazysite::Manager::Files::DOCROOT = $s->{docroot};
    ( my $parent = $beta ) =~ s{/[^/]+\z}{};
    ( my $bname  = $beta ) =~ s{\A.*/}{};
    ( my $aname  = $alpha ) =~ s{\A.*/}{};
    ok( length $parent && $parent ne $beta && $alpha =~ m{\A\Q$parent\E/}, "both roots sit in $parent/" ) or return;
    my $names = sub {
        my $l = Lazysite::Manager::Files::action_list( "/$parent", @_ );
        return ref $l eq 'HASH' && $l->{ok} ? { map { $_->{name} => 1 } @{ $l->{entries} || [] } } : {};
    };
    for my $c (
        [ 'a token naming no scope',         { token => 1, confined => 1 } ],
        [ 'a token granted the primary row', { token => 1, confined => 1, scopes => [$P] } ],
        [ 'a cookie manager granted nothing', { confined => 1 } ],
        )
    {
        my ( $label, $who ) = @$c;
        as(%$who);
        my $n = $names->();
        ok( !$n->{$bname} && !$n->{$aname}, "$label: neither domain's folder is listed" );
    }
    as( token => 1, confined => 1, scopes => [ $P, $alpha ] );
    my $n = $names->();
    ok( $n->{$aname} && !$n->{$bname}, 'granted alpha too: alpha is listed, beta is not' );
    as( token => 1, confined => 1 );
    $n = $names->( scopes => [ $P, $beta ] );
    ok( $n->{$bname} && !$n->{$aname}, 'a door naming the scopes is answered by them (MCP list_files)' );
    as( confined => 0 );
    $n = $names->();
    ok( $n->{$aname} && $n->{$bname}, 'the cookie operator sees both' );
};

subtest 'the refusal names the folder and how to grant it' => sub {
    my $m = Lazysite::Manager::Common::foreign_root_sentence( "$beta/x.md", $beta );
    like( $m, qr/another domain's content \(\Q$beta\E\/\)/, 'the folder' );
    like( $m, qr/allowed_groups/,                           'and the grant' );
};

done_testing();
