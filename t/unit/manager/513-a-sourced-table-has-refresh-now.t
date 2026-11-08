#!/usr/bin/perl
# SM1364 (ruling 191): THE DATA PAGE REFRESHES A SOURCED TABLE.
#
# A table that reads its rows from another system shows, above its rows, how old
# they are and how the last refresh went - read from the `source` block the
# data-table answer carries - and a Refresh now button that posts
# data-table-refresh and shows the answer's `source` in turn. A table with no
# source shows none of it.
#
# The renderer is run in node with a stand-in document, so the assertion is on
# what the page shows, not on the spelling of its source.
#
# With the change reverted the page has no source bar and no refresh, and every
# subtest fails.
use strict;
use warnings;
use Test::More;
use File::Temp ();
use JSON::PP   ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use PageScript ();

my $root = repo_root();
my $page = do {
    open my $fh, '<', "$root/starter/manager/data.md" or die $!;
    local $/;
    <$fh>;
};

subtest 'the rows panel has a Refresh now that posts data-table-refresh' => sub {
    like( $page, qr{<span id="source-bar" hidden>.*?id="source-refresh-btn" onclick="refreshSource\(\)">Refresh now</button>}s,
        'a hidden source bar holds the button' );
    my $fn = PageScript::extract_function( $page, 'refreshSource', 'data.md' );
    ok( $fn, 'refreshSource is defined' ) or return;
    like( $fn, qr/postJson\('data-table-refresh', \{ table: CURRENT\.table \}\)/, 'it posts the action for the open table' );
    like( $fn, qr/renderSource\(d\.source\)/, 'and shows the answer\'s source block' );
    like( $page, qr/renderSource\(CURRENT\.desc \? CURRENT\.desc\.source : null\)/,
        'the bar is filled from data-table when the rows open' );
};

chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
SKIP: {
    skip 'node not installed', 1 unless length $node && -x $node;
    subtest 'what the bar says' => sub {
        my $age = PageScript::extract_function( $page, 'sourceAge',    'data.md' );
        my $ren = PageScript::extract_function( $page, 'renderSource', 'data.md' );
        ok( $age && $ren, 'the renderer is present' ) or return;
        my $dir = File::Temp::tempdir( CLEANUP => 1 );
        open my $js, '>', "$dir/a.js" or die $!;
        print {$js} <<"JS";
var els = { 'source-bar': { hidden: true }, 'source-age': { textContent: '' } };
var document = { getElementById: function(id) { return els[id]; } };
$age
$ren
var out = {};
renderSource(null);
out.none = els['source-bar'].hidden;
renderSource({ connector: 'bookings', refreshed_at: 1, age_seconds: 600, outcome: 'failed',
  reason: 'the connector call failed (http 503)', read_only: ['guest', 'ref'] });
out.shown = !els['source-bar'].hidden;
out.text = els['source-age'].textContent;
renderSource({ connector: 'bookings', age_note: 'never refreshed: the schedule entry has not delivered yet' });
out.never = els['source-age'].textContent;
console.log(JSON.stringify(out));
JS
        close $js;
        my $o = JSON::PP::decode_json(`\Q$node\E \Q$dir/a.js\E 2>&1`);
        ok( $o->{none}, 'a table with no source shows no bar' );
        ok( $o->{shown}, 'a sourced table shows it' );
        like( $o->{text}, qr/connector bookings: refreshed 10 minutes ago/, 'with how old the rows are' );
        like( $o->{text}, qr/the last refresh failed - the connector call failed \(http 503\)/, 'and the last outcome' );
        like( $o->{text}, qr/Read-only here: guest, ref/, 'and which columns are the source\'s' );
        like( $o->{never}, qr/never refreshed/, 'a table never refreshed says so' );
    };
}

done_testing();
