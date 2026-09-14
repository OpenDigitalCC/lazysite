#!/usr/bin/perl
# N141B-F: the Stats page draws every visitor class the engine reports.
#
# The "Who's calling" tiles and the segmented bar below them were built from a
# list of five classes written into the page. The engine has six. The missing
# one was `scanner` - 8,714 visits, 58.7% of the traffic on the instrument - so
# the panel omitted the LARGEST class and then drew the remaining 41.3% as a
# complete bar, with every other segment's percentage inflated to match.
#
# A BAR THAT SUMS TO 100% OF THE WRONG DENOMINATOR IS WORSE THAN A MISSING
# ROW. A missing row is visibly missing. A full-width bar states that what it
# shows is all there is.
#
# plugins/stats.pl had already learned this and says so where it builds the
# payload: it derives `classes` from @CLASSES "so a sixth class cannot be left
# off this view the way `scanner` was left off the index". This page was the
# view it meant, and it held its own copy of the list - which is how it fell a
# release behind.
#
# THE JAVASCRIPT IS RUN, following t/unit/manager/121: what matters is which
# classes the code ENUMERATES from a payload, and a source grep for 'scanner'
# would pass on a page that mentions it in a comment.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $page = repo_root() . '/starter/manager/stats.md';
plan skip_all => "no $page" unless -f $page;
chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
plan skip_all => 'node not installed' unless length $node && -x $node;

my $src = do { open my $fh, '<', $page or die $!; local $/; <$fh> };

# The block that turns the payload's classes into the ordered draw list.
my ($block) = $src =~ /(var LABELS = \{.*?var defs = keys\.map\([^\n]*\);)/s;
ok( $block, 'the page carries the class-list builder' )
    or do { done_testing(); exit };

my $dir = tempdir( CLEANUP => 1 );
open my $js, '>', "$dir/classes.js" or die $!;
print {$js} <<"JS";
// The payload shape stats.pl sends: every class in \@CLASSES plus logged_in.
// The numbers are the proportions from the field report - scanner is the
// largest, which is what made its absence a wrong total rather than a gap.
var d = { classes: {
  human:     { hits: 4000, visitors: 48 },
  logged_in: { hits:  100, visitors:  3 },
  ai:        { hits:  200, visitors:  7 },
  bot:       { hits:  900, visitors: 20 },
  noise:     { hits:  950, visitors: 25 },
  scanner:   { hits: 8714, visitors: 61 }
} };
$block
var mix = defs.map(function (p) { return [p[0], COLOURS[p[0]] || '#8a8a8a']; });
var mixTotal = mix.reduce(function (s, p) { return s + ((d.classes[p[0]] || {}).hits || 0); }, 0);
var total = Object.keys(d.classes).reduce(function (s, k) { return s + d.classes[k].hits; }, 0);
console.log(JSON.stringify({
  keys: defs.map(function (p) { return p[0]; }),
  labels: defs.map(function (p) { return p[1]; }),
  mixTotal: mixTotal,
  total: total,
  colours: mix.map(function (p) { return p[1]; })
}));
JS
close $js;

my $got = eval {
    require JSON::PP;
    JSON::PP::decode_json(`\Q$node\E \Q$dir/classes.js\E 2>&1`);
};
ok( $got, 'the class-list builder ran' ) or do { done_testing(); exit };

# --- every class the engine sent is drawn ------------------------------------
for my $c (qw(human logged_in ai bot noise scanner)) {
    ok( ( grep { $_ eq $c } @{ $got->{keys} } ), "the '$c' class is drawn" );
}

# --- and the bar's denominator is the WHOLE traffic --------------------------
is( $got->{mixTotal}, $got->{total},
    'the bar sums every class, so its percentages are of all traffic' )
    or diag( "the bar totalled $got->{mixTotal} of $got->{total} - the missing "
        . 'share is drawn as if it did not exist, and every segment shown is '
        . 'inflated by the difference.' );

# --- the largest class is not the one left out -------------------------------
#
# Stated as its own assertion because it is the specific harm: `scanner` was
# 58.7% of traffic and the panel drew a complete-looking bar of the other 41.3%.
ok( ( grep { $_ eq 'scanner' } @{ $got->{keys} } ),
    'scanner - the largest class on the instrument - is among them' );

# --- a class the page has no label for is still drawn ------------------------
#
# The list comes from the payload now, so a seventh class appears the day the
# engine reports one. Unlabelled is untidy; absent from a total is wrong.
open my $js2, '>', "$dir/unknown.js" or die $!;
print {$js2} <<"JS";
var d = { classes: { human: { hits: 10, visitors: 1 }, newcomer: { hits: 90, visitors: 9 } } };
$block
var mixTotal = defs.reduce(function (s, p) { return s + ((d.classes[p[0]] || {}).hits || 0); }, 0);
console.log(JSON.stringify({ keys: defs.map(function (p) { return p[0]; }),
                             labels: defs.map(function (p) { return p[1]; }),
                             mixTotal: mixTotal }));
JS
close $js2;
my $un = eval { JSON::PP::decode_json(`\Q$node\E \Q$dir/unknown.js\E 2>&1`) };
ok( $un, 'the builder ran against an unknown class' ) or do { done_testing(); exit };

ok( ( grep { $_ eq 'newcomer' } @{ $un->{keys} } ),
    'a class this page has never heard of is still drawn' )
    or diag( 'This is the whole point of deriving the list: the next class '
        . 'must not need a release of this page to be counted.' );
is( $un->{mixTotal}, 100, 'and counted in the total' );
ok( ( grep { $_ eq 'newcomer' } @{ $un->{labels} } ),
    'falling back to its own key as the label' );

# --- the tile no longer claims to count everyone -----------------------------
#
# Against the CODE, not the file. The comments below both fixes quote the old
# wording to explain what was removed - which is exactly what a removal comment
# should do - and a check reading the whole file would trip on the explanation
# of the thing it is verifying was deleted. (t/lint/142 learned this the same
# way, on my own correction.)
( my $code = $src ) =~ s{^\s*//.*$}{}mg;

unlike( $code, qr/tile\('Unique visitors'/,
    'the human-only figure is not labelled "Unique visitors"' )
    or diag( 'It showed 48 where totals.unique_visitors was 153 - the same '
        . 'field name meaning two different measurements on two surfaces. The '
        . 'VALUE is deliberate (it pairs with a human-only Page views); the '
        . 'label was the wrong half.' );

# --- and the panel does not report a scan it never made ----------------------
unlike( $code, qr/log lines scanned/,
    'the page does not print a line count nothing measures' )
    or diag( 'scanned_lines is sent by nothing in the tree, and fmtNum turns '
        . 'undefined into 0 - so this rendered the constant "0 log lines '
        . 'scanned." under a full panel, on every load.' );

done_testing();
