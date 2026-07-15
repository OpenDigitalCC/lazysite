#!/usr/bin/perl
# SEC-2026-07 (H5): a content author's front-matter title/subtitle/author is
# attacker-controllable and was emitted unescaped in the fallback layout's
# visible <title>/<h1>/<p> tags (and every library layout). It is now escaped
# at the stash source in render_content, so no sink can break out - including
# layouts we cannot edit from this repo. Renders through the built-in fallback
# layout (no layout configured) which carries all four sinks.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor);

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite");
open my $conf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print $conf "site_name: Test\n";
close $conf;

# A page whose title, subtitle and author all carry a <script> breakout.
open my $pg, '>', "$docroot/evil.md" or die $!;
print $pg <<'MD';
---
title: "</title><script>alert(1)</script>"
subtitle: "\"><script>alert(2)</script>"
author: "</x><script>alert(3)</script>"
---
Body.
MD
close $pg;

my $out = run_processor( $docroot, '/evil' );

ok( length $out, 'page rendered' );

# No raw <script> from any of the three fields survives to the output.
unlike( $out, qr/<script>alert\(1\)/, 'title breakout neutralised' );
unlike( $out, qr/<script>alert\(2\)/, 'subtitle breakout neutralised' );
unlike( $out, qr/<script>alert\(3\)/, 'author breakout neutralised' );

# The escaped forms are present (proves the value rendered, just safely).
like( $out, qr/&lt;script&gt;alert\(1\)/, 'title emitted HTML-escaped' );

# And it must not be double-escaped (no &amp;lt;) in the description meta.
unlike( $out, qr/&amp;lt;script&gt;alert\(2\)/,
    'subtitle not double-escaped in <meta description>' );

done_testing();
