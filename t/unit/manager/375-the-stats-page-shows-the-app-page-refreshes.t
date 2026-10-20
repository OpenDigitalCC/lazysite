#!/usr/bin/perl
# SM1212: the Stats page shows the installed app's page refreshes (app_hits,
# SM1203) as a tile beside Page views and Images and files, and shows nothing
# when the app made none. The tile expression is lifted out of the page and run.
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use PageScript ();

my $page = repo_root() . '/starter/manager/stats.md';
plan skip_all => "no $page" unless -f $page;
chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
plan skip_all => 'node not installed' unless length $node && -x $node;

my $src      = do { open my $fh, '<', $page or die $!; local $/; <$fh> };
my $tilefn   = PageScript::extract_function( $src, 'tile', 'starter/manager/stats.md' ) . "\n";
my ($expr)   = $src =~ /(\(d\.app_hits \? tile\(.*?\) : ''\))/s;
ok( $tilefn, 'the page carries the tile builder' );
ok( $expr,   'and a tile for d.app_hits' ) or do { done_testing(); exit };

my $dir = tempdir( CLEANUP => 1 );
open my $o, '>', "$dir/t.js" or die $!;
print {$o} <<"JS";
function sesc(s) { return String(s); }
function fmtNum(n) { return String(n); }
$tilefn
function draw(d) { return $expr; }
var withApp = draw({ app_hits: 12 });
var none    = draw({});
var zero    = draw({ app_hits: 0 });
console.log(JSON.stringify({ withApp: withApp, none: none, zero: zero }));
JS
close $o;
my $out = `$node $dir/t.js 2>&1`;
my $r   = eval { JSON::PP::decode_json($out) } or BAIL_OUT("node said: $out");
like( $r->{withApp}, qr/>12<.*App page refreshes/s, 'the figure is drawn with its label' );
is( $r->{none}, '', 'no tile when the payload has no app_hits' );
is( $r->{zero}, '', 'and none for a zero' );

done_testing();
