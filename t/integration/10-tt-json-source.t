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

done_testing;
