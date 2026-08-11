#!/usr/bin/perl
# SEC-2026-07 (M2): path_out_of_scope() - the shared dav_scope confinement the
# MCP and control-API channels apply (parity with WebDAV). An empty scope
# confines nothing; a set scope permits the scope dir and its subtree only.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Common qw(path_out_of_scope outside_all_scopes);

# Unscoped credential: nothing is confined.
ok( !path_out_of_scope( '',    '/anything/at/all.md' ), 'empty scope confines nothing' );
ok( !path_out_of_scope( undef, '/anything.md' ),        'undef scope confines nothing' );

# Scope = content/clientA (with or without slashes on the scope itself).
for my $scope ( 'content/clientA', '/content/clientA', 'content/clientA/' ) {
    ok( !path_out_of_scope( $scope, 'content/clientA' ), "in scope: the scope dir itself ($scope)" );
    ok( !path_out_of_scope( $scope, '/content/clientA/ok.md' ), "in scope: a file below it ($scope)" );
    ok( !path_out_of_scope( $scope, 'content/clientA/deep/x' ), "in scope: a deep file ($scope)" );
    ok( path_out_of_scope( $scope, '/content/clientB/secret.md' ), "out of scope: a sibling ($scope)" );
    ok( path_out_of_scope( $scope, '/content/clientA-evil/x.md' ), "out of scope: sibling-prefix (no boundary escape) ($scope)" );
    ok( path_out_of_scope( $scope, '/etc/passwd' ), "out of scope: elsewhere ($scope)" );
}

# --- SM155: outside_all_scopes - the UNION of several group scopes ----------
{
    my @two = ( 'content/clientA', 'content/clientB' );
    ok( !outside_all_scopes( \@two, '/content/clientA/x.md' ), 'union: within the first scope is allowed' );
    ok( !outside_all_scopes( \@two, '/content/clientB/y.md' ), 'union: within the second scope is allowed' );
    ok( outside_all_scopes( \@two, '/content/clientC/z.md' ), 'union: outside every scope is denied' );
    ok( !outside_all_scopes( [], '/anything' ), 'union: an empty set confines nothing' );
    ok( !outside_all_scopes( undef, '/anything' ), 'union: undef set confines nothing' );
}

# SM279: the group_scopes / group_home_domain block that used to sit here has
# been REMOVED with the resolvers it tested. They read a group's `dav_scope`,
# which SM165 stopped consulting in 0.7.26 - so from that release the block was
# testing dead code, passing, and saying nothing about whether anyone was
# actually confined. A test that pins a resolver nothing calls is worse than no
# test: it reads as coverage.
#
# What remains above is the live half - path_out_of_scope and outside_all_scopes
# are what every channel calls to enforce a scope, whatever produced it. The
# SOURCE of scopes is covered by t/unit/lib/20-domain-access.t, and the
# retirement itself by t/unit/users/26-group-scope-retired.t.

done_testing();
