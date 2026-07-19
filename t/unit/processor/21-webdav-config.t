#!/usr/bin/perl
# The WebDAV site toggle (webdav_enabled) must be settable + surfaced through the
# control API so the manager Config page can enable it - the dav gate returns 404
# for every method until it is on. SM042: site settings are now managed via
# config-read / config-set (NOT the processor's pseudo-plugin schema), so this
# pins the new source of truth and that the retired schema is gone.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; <$fh> }
my $api = slurp("$root/lazysite-manager-api.pl");
my $cfg = slurp("$root/starter/manager/config.md");

# --- new source of truth: config-set (write) + config-read (surface) -----------
my ($allow) = $api =~ /my %allow = map \{ \$_ => 1 \}\s*\n\s*qw\((.*?)\)/s;
ok( $allow && $allow =~ /\bwebdav_enabled\b/,
    'webdav_enabled is settable via the control API (config-set allow-list)' );

my ($readset) = $api =~ /sub action_config_read \{.*?qw\((.*?)\)/s;
ok( $readset && $readset =~ /\bwebdav_enabled\b/,
    'webdav_enabled is surfaced by config-read (so the Config panel shows its state)' );

# --- the Config page renders it -----------------------------------------------
like( $cfg, qr/key:\s*'webdav_enabled'/,
    'config.md SITE_SCHEMA offers webdav_enabled on the Config page' );

# --- the retired coupling stays retired ---------------------------------------
my $out = `$^X $root/lazysite-processor.pl --describe 2>/dev/null`;
my $d   = eval { decode_json($out) }
    or BAIL_OUT("lazysite-processor.pl --describe did not return JSON");
ok( !exists $d->{config_schema} && !exists $d->{config_keys},
    'the processor --describe no longer carries the site-config schema (SM042: config-set/read own it)' );
unlike( $cfg, qr/mirrors\s+lazysite-processor\.pl/i,
    'config.md no longer claims to mirror the processor schema (drift hazard removed)' );

done_testing();
