#!/usr/bin/perl
# SM1223, the browser half: starter/assets/lazysite-odoo.js sends a page's key as the
# Idempotency-Key header of ONE call - write() and confirm(), with or without a file -
# and keeps it when the call is sent again (a stale token), which is the point of a
# key. A call given none sends no header. The key is never in the body or the token GET.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root  = repo_root();
my $asset = "$root/starter/assets/lazysite-odoo.js";
my $node  = `sh -c 'command -v node || command -v nodejs' 2>/dev/null`;
chomp $node;
plan skip_all => 'node is not installed' unless length $node && -x $node;

my $out = `$node "$root/t/lib/odoo-idem-harness.js" "$asset" 2>&1`;
my $f   = eval { decode_json($out) };
ok( $f && !$f->{error}, 'the idem harness ran' ) or BAIL_OUT("harness: $out");

is( $f->{write}{n},   1,                      'a keyed write is one POST' );
is( $f->{write}{key}, 'queue-item-0001-aaaa', 'carrying the Idempotency-Key header' );
ok( !$f->{write}{body_has_key}, 'and not in the body' );
ok( !$f->{write}{get_has_key},  'nor on the token fetch' );
ok( !defined $f->{none},        'a write given no key sends no header' );
is_deeply( $f->{retry}, [ 'queue-item-0002-bbbb', 'queue-item-0002-bbbb' ], 'a call sent again after a stale token keeps its key' );
is( $f->{confirm}{key}, 'confirm-key-0003-cc', 'a confirm takes one' );
ok( $f->{confirm}{confirm}, 'as a confirm' );
ok( $f->{upload}{form},     'a file upload is multipart' );
is( $f->{upload}{key}, 'upload-item-0004-dd', 'and carries it' );

done_testing;
