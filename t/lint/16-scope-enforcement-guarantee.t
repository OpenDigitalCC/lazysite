#!/usr/bin/perl
# SECURITY GUARANTEE (adversarial breadth, 2026-07): a dav_scope-confined
# credential (a delegated editor bound to content/clientA) must be confined
# IDENTICALLY on every channel it can act through - the control-API token and
# cookie paths, the MCP server, and WebDAV. The confinement ALGORITHM is unit-
# tested in t/unit/manager/30-dav-scope.t (outside_all_scopes: empty set =
# unconfined, non-empty = deny outside every scope, prefix-escape safe). What
# THIS test pins is that each channel actually ROUTES its file access through
# that shared helper, so a new channel (or a refactor) cannot silently drop the
# confinement on one door while the others hold.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
sub slurp { open my $fh, '<', $_[0] or die "open $_[0]: $!"; local $/; <$fh> }

# The single shared confinement helper.
my $common = slurp("$root/lib/Lazysite/Manager/Common.pm");
like( $common, qr/sub outside_all_scopes\b/,
    'the shared union-scope helper outside_all_scopes exists' );

# --- control-API: BOTH the cookie and the token path confine -------------------
my $mapi = slurp("$root/lazysite-manager-api.pl");
like( $mapi, qr/sub _confine_scope\b/, 'control-API defines _confine_scope' );
like( $mapi, qr/outside_all_scopes\(/,
    '_confine_scope enforces via the shared outside_all_scopes helper' );
my @confine_calls = $mapi =~ /_confine_scope\(/g;
cmp_ok( scalar @confine_calls, '>=', 2, 'control-API invokes _confine_scope on the cookie AND token paths (2 call sites)' );
# The two enforcement channels are labelled 'ui' (cookie) and 'api' (token).
like( $mapi, qr/_confine_scope\([^)]*'ui'\s*\)/, 'the cookie (ui) path is scope-confined' );
like( $mapi, qr/_confine_scope\([^)]*'api'\s*\)/, 'the token (api) path is scope-confined' );

# --- MCP: read AND write file tools confine ------------------------------------
my $mcp       = slurp("$root/lazysite-mcp.pl");
my @mcp_scope = $mcp =~ /outside_all_scopes\(/g;
cmp_ok( scalar @mcp_scope, '>=', 2,
    'the MCP server confines multiple file operations (read + write) via outside_all_scopes' );

# --- WebDAV: the request resolves a scope and authorises the path against it ----
my $dav = slurp("$root/lazysite-dav.pl");
like( $dav, qr/my \$scope\s*=\s*scope_for\(/,
    'WebDAV resolves the credential scope for the request' );
like( $dav, qr/authorise\(\s*\$rel\s*,\s*\$scope\b/,
    'WebDAV authorises the request path against the resolved scope' );
like( $dav, qr/sub scope_for\b/, 'WebDAV scope_for resolves from the user groups' );

done_testing;
