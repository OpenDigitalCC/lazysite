#!/usr/bin/perl
# SEC-2026-07 (M2): path_out_of_scope() - the shared dav_scope confinement the
# MCP and control-API channels apply (parity with WebDAV). An empty scope
# confines nothing; a set scope permits the scope dir and its subtree only.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Common qw(path_out_of_scope);

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

done_testing();
