#!/usr/bin/perl
# DRIFT GUARD (SM042): the Config page (starter/manager/config.md) renders its
# form from SITE_SCHEMA, loads values via the control API's config-read, and
# saves each key via config-set. Those are three representations of the same key
# set; if they drift, a toggle renders but never persists (or shows blank) - the
# exact 0.9.0 bug where the service killswitches saved through the retired
# pseudo-plugin path and silently vanished. This test fails the build unless:
#   - every key the page SHOWS is surfaced by config-read, and
#   - every SETTABLE key the page offers is in config-set's write allow-list.
# It is the mechanical replacement for the old "config.md must stay in sync"
# comment that this class of bug slipped through.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; <$fh> }

my $cfg = slurp("$root/starter/manager/config.md");
my $api = slurp("$root/lazysite-manager-api.pl");

# --- parse SITE_SCHEMA: each key + whether it is readonly (not settable) --------
my ($schema) = $cfg =~ /var SITE_SCHEMA = \[(.*?)\n\];/s;
ok( $schema, 'found SITE_SCHEMA in config.md' );
my %page_key;    # key => readonly?(0/1)
# Split into entries at each "{ key:" so type is scoped to its own entry.
for my $entry ( split /\{\s*key\s*:/, $schema ) {
    next unless $entry =~ /^\s*'([a-z0-9_]+)'/;
    my $key = $1;
    $page_key{$key} = ( $entry =~ /readonly_with_link/ ) ? 1 : 0;
}
cmp_ok( scalar keys %page_key, '>=', 10, 'SITE_SCHEMA parsed non-trivially' );

# --- config-set write allow-list -----------------------------------------------
my ($allow_blk) = $api =~ /my %allow = map \{ \$_ => 1 \}\s*\n\s*qw\((.*?)\)/s;
ok( $allow_blk, 'found config-set %allow' );
my %settable = map { $_ => 1 } split ' ', $allow_blk;

# --- config-read surfaced subset -----------------------------------------------
my ($read_blk) = $api =~ /sub action_config_read \{.*?my %out = map \{ \$_ => '' \}\s*\n\s*qw\((.*?)\)/s;
ok( $read_blk, 'found config-read subset' );
my %surfaced = map { $_ => 1 } split ' ', $read_blk;

# --- 1. every page key is surfaced by config-read (so it displays) -------------
my @not_read = sort grep { !$surfaced{$_} } keys %page_key;
is( "@not_read", '',
    'every Config-page key is surfaced by config-read (page can display its value)' )
    or diag "PAGE KEYS MISSING FROM config-read: @not_read";

# --- 2. every SETTABLE page key is in config-set's allow-list (so it saves) -----
my @not_settable = sort grep { !$page_key{$_} && !$settable{$_} } keys %page_key;
is( "@not_settable", '',
    'every settable Config-page key is in config-set (page can persist it)' )
    or diag "SETTABLE PAGE KEYS MISSING FROM config-set (would silently not save): @not_settable";

# --- non-vacuity: the keys that caused / neighbour the 0.9.0 bug are covered ----
for my $k (qw(webdav_enabled mcp_enabled oauth_enabled control_api_enabled
    token_exchange_enabled manager)) {
    ok( $page_key{$k} == 0 && $settable{$k} && $surfaced{$k},
        "$k round-trips: on the page (settable) + in config-set + in config-read" );
}

done_testing;
