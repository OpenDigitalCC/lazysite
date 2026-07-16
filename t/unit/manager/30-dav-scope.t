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

# --- SM155: group_scopes / group_home_domain resolve from groups-settings ---
{
    use File::Temp qw(tempdir);
    use File::Path qw(make_path);
    require Lazysite::Auth::Settings;
    Lazysite::Auth::Settings->import(qw(group_scopes group_home_domain));
    my $d = tempdir( CLEANUP => 1 );
    open my $fh, '>', "$d/groups-settings.json" or die $!;
    print $fh '{"clienta":{"dav_scope":"/content/clienta","home_domain":"clienta.com"},'
        . '"clientb":{"dav_scope":"/content/clientb"},"plain":{"manage_content":1}}';
    close $fh;
    local $Lazysite::Auth::Settings::AUTH_DIR = $d;

    is_deeply( [ sort( Lazysite::Auth::Settings::group_scopes('clienta') ) ],
        ['/content/clienta'], 'group_scopes: one scoped group' );
    is_deeply( [ sort( Lazysite::Auth::Settings::group_scopes( 'clienta', 'clientb', 'plain' ) ) ],
        [ '/content/clienta', '/content/clientb' ], 'group_scopes: union of scoped groups, plain ignored' );
    is( Lazysite::Auth::Settings::group_home_domain('clienta'), 'clienta.com',
        'group_home_domain: single scoped group -> its home_domain' );
    is( Lazysite::Auth::Settings::group_home_domain( 'clienta', 'clientb' ), '',
        'group_home_domain: multiple scoped groups -> none (switcher case)' );
}

done_testing();
