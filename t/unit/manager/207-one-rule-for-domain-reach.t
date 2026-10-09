#!/usr/bin/perl
# SM976: one rule for domain reach - Lazysite::Manager::Common::caller_may_reach_domain.
#
# Every action addressed by a host or a content root asks this one predicate,
# on the control API, MCP and WebDAV (t/lint/218 holds that). This file is its
# truth table, caller by caller and target by target, so a change to the rule
# is a change to a table rather than a surprise in one surface.
#
# The instance: alpha.test at sites/alpha, beta.test at sites/beta,
# sub.alpha.test at sites/alpha/inner, mirror.test with no content root (it
# serves the primary's content), and the primary.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root setup_multi_domain_site);
use lib repo_root() . '/lib';
use Lazysite::Manager::Common qw(caller_may_reach_domain reachable_domains domain_reach_refusal
    reset_request_context $token_auth %token_caps @REQUEST_SCOPES $REQUEST_CONFINED $IS_OPERATOR);
use Lazysite::Manager::Domains ();

my $s = setup_multi_domain_site( extra_conf => "alias_hosts: alpha.test, beta.test, sub.alpha.test, mirror.test\n" );
$Lazysite::Manager::Common::DOCROOT  = $s->{docroot};
$Lazysite::Manager::Domains::DOCROOT = $s->{docroot};

my @TARGETS = (
    [ host => 'alpha.test' ],       [ host => 'beta.test' ], [ host => 'sub.alpha.test' ],
    [ host => 'mirror.test' ],      [ host => '' ],          [ host => '(default)' ],
    [ host => 'unserved.example' ], [ root => 'sites/alpha/new' ], [ root => 'sites/else' ],
    [ root => '' ],
);
sub label { my ( $k, $v ) = @_; return "$k " . ( length $v ? $v : "''" ) }

# The request a dispatcher would have established.
sub as {
    my (%c) = @_;
    reset_request_context();
    $token_auth       = $c{token} ? 1 : 0;
    @REQUEST_SCOPES   = @{ $c{scopes} || [] };
    %token_caps       = ( dav_scopes => [ @{ $c{scopes} || [] } ] );
    $REQUEST_CONFINED = $c{confined} ? 1 : 0;
    $IS_OPERATOR      = $c{operator} ? 1 : 0;
    return;
}

#            alpha beta sub mirror '' (default) unserved new else root''
my %TABLE = (
    'the cookie operator'                 => [ { operator => 1 }, 'YYYYYYYYYY' ],
    'a cookie manager bound to no domain' => [ { confined => 1 }, 'YYYYYYYYYY' ],
    'a cookie manager scoped to alpha' => [ { confined => 1, scopes => ['sites/alpha'] }, 'YNYNNNNYNN' ],
    'a token scoped to alpha' => [ { token => 1, confined => 1, scopes => ['sites/alpha'] }, 'YNYNNNNYNN' ],
    'a token scoped into alpha only' => [ { token => 1, confined => 1, scopes => ['sites/alpha/inner'] }, 'NNYNNNNNNN' ],
    'a token scoped to alpha and beta' => [ { token => 1, confined => 1, scopes => [ 'sites/alpha', 'sites/beta' ] }, 'YYYNNNNYNN' ],
    'a token naming no scope' => [ { token => 1, confined => 1 }, 'NNNYYYNNNY' ],
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

# The explicit form MCP and WebDAV use: every grant is confined to what it names.
subtest 'a grant passed as scopes => [...]' => sub {
    as( operator => 1 );    # the request context must not leak into the answer
    ok( caller_may_reach_domain( scopes => ['sites/alpha'], host => 'alpha.test' ), 'its own domain' );
    ok( !caller_may_reach_domain( scopes => ['sites/alpha'], host => 'beta.test' ), 'not another' );
    ok( !caller_may_reach_domain( scopes => ['sites/alpha'], host => '' ), 'not the primary' );
    ok( !caller_may_reach_domain( scopes => [], host => 'alpha.test' ), 'no scope: no domain' );
    ok( caller_may_reach_domain( scopes => [], host => '' ), 'no scope: the primary, as content' );
};

# SM976 R3 (ruled 2026-10-09, "Keep for primary"): an UNBOUND token, MCP grant
# or WebDAV account reaches the primary - and a domain serving the primary's
# content - by the content-path rule; every other domain needs a scope (SM975).
# The table above holds it for the token; this names the ruling and holds it for
# the grant form MCP and WebDAV pass, and for the listing a client is shown.
subtest 'R3: an unbound token or grant reaches the primary and no other domain' => sub {
    as( token => 1, confined => 1 );
    is_deeply( [ reachable_domains() ], [ '(default)', 'mirror.test' ], 'a token: the primary and the mirror' );
    as( operator => 1 );
    is_deeply( [ reachable_domains( scopes => [] ) ], [ '(default)', 'mirror.test' ], 'a grant: the same' );
    for my $h ( 'alpha.test', 'beta.test', 'sub.alpha.test' ) {
        ok( !caller_may_reach_domain( scopes => [], host => $h ), "a grant: not $h" );
    }
};

# SM976 R1 (ruled 2026-10-09, "Confined = no instance-wide"): who is refused an
# instance-wide write. Confined means a confined channel AND a scope naming some
# domain(s) - the callers the predicate refuses the primary to. The unbound
# token keeps them (it reaches the primary, whose settings they are), and so do
# the operator and an unbound cookie manager.
subtest 'R1: caller_is_confined and instance_wide_refusal' => sub {
    my %WHO = (
        'the cookie operator'                 => [ { operator => 1 }, 0 ],
        'a cookie manager bound to no domain' => [ { confined => 1 }, 0 ],
        'a cookie manager scoped to alpha' => [ { confined => 1, scopes => ['sites/alpha'] }, 1 ],
        'a token naming no scope'          => [ { token => 1, confined => 1 }, 0 ],
        'a token scoped to alpha' => [ { token => 1, confined => 1, scopes => ['sites/alpha'] }, 1 ],
        'a locked account confined to nothing' => [ { confined => 1, scopes => ["\0sm165-locked-nowhere"] }, 1 ],
    );
    for my $who ( sort keys %WHO ) {
        my ( $ctx, $want ) = @{ $WHO{$who} };
        as(%$ctx);
        is( Lazysite::Manager::Common::caller_is_confined(), $want, "$who: " . ( $want ? 'confined' : 'not confined' ) );
        my $r = Lazysite::Manager::Common::instance_wide_refusal( action => 'config-set' );
        if ($want) {
            is( $r->{kind}, 'forbidden', "$who: config-set refused" );
            ok( $r->{instance_wide}, '...as an instance-wide write' );
            like( $r->{error}, qr/'config-set' changes the whole instance.*own domains only/s, '...saying why' );
        }
        else {
            is( $r, undef, "$who: config-set allowed" );
        }
    }
    as( operator => 1 );    # the explicit form must not read the request context
    ok( Lazysite::Manager::Common::caller_is_confined( scopes => ['sites/alpha'] ), 'a grant with a scope: confined' );
    ok( !Lazysite::Manager::Common::caller_is_confined( scopes => [] ), 'an unbound grant: not confined' );
    is_deeply( Lazysite::Manager::Common::instance_wide_refusal( action => 'x', scopes => ['sites/alpha'] )->{domains},
        [qw(alpha.test sub.alpha.test)], 'the refusal lists the domains it does act on' );
    reset_request_context();
    ok( Lazysite::Manager::Common::caller_is_confined(), 'and with no request context, everyone is confined' );
};

subtest 'loaded where no request set the context, it reaches nothing' => sub {
    reset_request_context();
    is_deeply( [ grep { caller_may_reach_domain( @{$_} ) } @TARGETS ], [], 'every target is refused' );
};

subtest 'the refusal names the scope and the domains the caller does reach' => sub {
    as( token => 1, confined => 1, scopes => ['sites/alpha'] );
    is_deeply( [ reachable_domains() ], [qw(alpha.test sub.alpha.test)], 'reachable_domains' );
    my $r = domain_reach_refusal( host => 'beta.test' );
    is( $r->{kind}, 'forbidden', 'forbidden' );
    like( $r->{error}, qr/beta\.test.*sites\/alpha\/.*alpha\.test, sub\.alpha\.test/s, 'says why and what instead' );
    is_deeply( $r->{domains}, [qw(alpha.test sub.alpha.test)], 'and lists them for a client to pick from' );
    is( domain_reach_refusal( host => 'alpha.test' ), undef, 'no refusal for its own domain' );
};

done_testing();
