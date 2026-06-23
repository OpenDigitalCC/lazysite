#!/usr/bin/perl
# The WebDAV site toggle (webdav_enabled) is exposed as a writable site-config
# key + a schema field, so the manager Config page can enable it - the dav
# gate returns 404 for every method until it is on. config.md mirrors the
# schema and must stay in lock-step.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $out  = `$^X $root/lazysite-processor.pl --describe 2>/dev/null`;
my $d    = eval { decode_json($out) }
    or BAIL_OUT("lazysite-processor.pl --describe did not return JSON");

ok( ( grep { $_ eq 'webdav_enabled' } @{ $d->{config_keys} || [] } ),
    'webdav_enabled is a writable site-config key (plugin-save allows it)' );

my ($field) = grep { $_->{key} eq 'webdav_enabled' } @{ $d->{config_schema} || [] };
ok( $field, 'webdav_enabled has a config_schema field (renders on Config)' );
is( $field->{type}, 'select', 'rendered as a select toggle' )
    if $field;

open my $fh, '<', "$root/starter/manager/config.md" or die $!;
my $cfg = do { local $/; <$fh> };
close $fh;
like( $cfg, qr/key:\s*'webdav_enabled'/,
    'config.md SITE_SCHEMA mirrors webdav_enabled' );

done_testing();
