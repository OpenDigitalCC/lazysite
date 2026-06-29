#!/usr/bin/perl
# tt_page_var `json:` source - a page loads a local JSON file as a real data
# structure and loops it in the body ([% FOREACH %]). Out-of-tree / missing /
# invalid sources degrade to an empty value (no error).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor);

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite", "$docroot/data");

open my $c, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print $c "site_name: Test\n";
close $c;
open my $j, '>', "$docroot/data/matrix.json" or die $!;
print $j '{"title":"Compare","rows":[{"name":"Alpha","value":"1"},{"name":"Beta","value":"2"}]}';
close $j;
open my $nf, '>', "$docroot/404.md" or die $!;
print $nf "---\ntitle: NF\n---\nNF.\n";
close $nf;

open my $p, '>', "$docroot/matrix.md" or die $!;
print $p <<'MD';
---
title: Matrix
tt_page_var:
  data: json:/data/matrix.json
  missing: json:/data/nope.json
---
H:[% data.title %]
[% FOREACH r IN data.rows %]ROW:[% r.name %]=[% r.value %];[% END %]
MISS:[% FOREACH r IN missing.rows %]X[% END %]done
MD
close $p;

my $out = run_processor( $docroot, '/matrix' );

like( $out, qr{H:Compare}, 'json: top-level scalar accessible' );
like( $out, qr{ROW:Alpha=1;}, 'json: looped row 1' );
like( $out, qr{ROW:Beta=2;},  'json: looped row 2' );
like( $out, qr{MISS:done},    'missing json: source degrades to empty - page still renders' );
unlike( $out, qr{MISS:X},     'missing json: source yields no rows' );

# Non-ASCII content must decode (read raw bytes, not :utf8 - else decode_json
# chokes and the whole file silently resolves to empty).
open my $u, '>:raw', "$docroot/data/utf8.json" or die $!;
# Double-quoted so the \xNN escapes become real UTF-8 bytes on disk.
print $u "{\"rows\":[{\"label\":"
       . "\"Fast \xE2\x80\x94 really \xE2\x80\x9Cgood\xE2\x80\x9D \xE2\x86\x92 yes\"}]}";
close $u;
open my $p2, '>', "$docroot/u8.md" or die $!;
print $p2 "---\ntitle: U8\nraw: true\ntt_page_var:\n  data: json:/data/utf8.json\n---\n"
        . "[% FOREACH r IN data.rows %]U8:[% r.label %]:rows=[% data.rows.size %][% END %]\n";
close $p2;
my $u8 = run_processor( $docroot, '/u8' );
utf8::decode($u8);    # subprocess returns UTF-8 bytes; compare as characters
like( $u8, qr{U8:Fast \x{2014} really \x{201C}good\x{201D} \x{2192} yes:rows=1},
    'json: decodes non-ASCII (em dash, curly quotes, arrow) instead of resolving empty' );

done_testing;
