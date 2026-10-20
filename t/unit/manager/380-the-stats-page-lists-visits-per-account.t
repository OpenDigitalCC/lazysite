#!/usr/bin/perl
# SM1219 (#339, ruled 2026-10-20): "per-account visits are shown in the manager".
#
# The Stats page draws a card, Visits by account, from analyse_visitors with
# by_account - the call the analytics capability gates and a domain-confined
# caller is answered for its own domains in - so the page needs no rule of its own.
# What the page itself owns, and this holds:
#
#   it asks for by_account, over the window the page states
#   the list is a row per account: the account, its visits, days and last visit
#   an account name is escaped (a name is typed by whoever made the account)
#   no visits is said as a fact; a refusal leaves the card hidden, not an error
#   the card adds no inline event handler
#
# The function is lifted out of the shipped page and run in node with a stub
# document and a stub fetch, so it is the page's own code that is measured.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP   ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root  = repo_root();
my $pagef = "$root/starter/manager/stats.md";
plan skip_all => "no $pagef" unless -f $pagef;
chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
plan skip_all => 'node not installed' unless length $node && -x $node;

my $page = do { open my $fh, '<', $pagef or die $!; local $/; <$fh> };

my ($fn)   = $page =~ /(function loadAccounts\(\) \{.*?\n\}\n)/s;
my ($sesc) = $page =~ /(function sesc\([^)]*\) \{[^\n]*\})/;
my ($num)  = $page =~ /(function fmtNum\([^)]*\) \{[^\n]*\})/;
ok( $fn && $sesc && $num, 'the card\'s function and the helpers it uses are in the page' )
    or BAIL_OUT('nothing to run');

like( $page, qr/id="accounts-card" hidden/, 'the card is hidden until there is something to say' );
like( $page, qr/Visits by account/,         'and is titled for what it lists' );
unlike( $fn, qr/\bon(?:click|change|load|error)\s*=/i, 'and adds no inline event handler' );

my $dir = tempdir( CLEANUP => 1 );

sub run_card {
    my ($reply) = @_;
    my $json = JSON::PP->new->encode($reply);
    my $js   = <<"JS";
var API = '/cgi-bin/lazysite-manager-api.pl';
var els = { 'accounts-card': { hidden: true }, 'accounts-body': { innerHTML: '' } };
var document = { getElementById: function (id) { return els[id]; }, createElement: function () {
  var o = { set textContent(v) { this._t = v; }, get innerHTML() {
    return String(this._t).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); } }; return o; } };
var asked = [];
function fetch(u) { asked.push(u); return Promise.resolve({ json: function () { return Promise.resolve($json); } }); }
$sesc
$num
$fn
loadAccounts();
setTimeout(function () {
  console.log(JSON.stringify({ asked: asked, hidden: els['accounts-card'].hidden, html: els['accounts-body'].innerHTML }));
}, 20);
JS
    open my $fh, '>', "$dir/card.js" or die $!;
    print {$fh} $js;
    close $fh;
    my $out = `\Q$node\E \Q$dir/card.js\E 2>&1`;
    return eval { JSON::PP::decode_json($out) } || { err => $out };
}

my $r = run_card( { ok => JSON::PP::true, by_account => { accounts => [
    { account => 'alice',         visits => 12, agent_visits => 0, days => 3, last => '2026-10-20' },
    { account => '<b>x</b>&"',    visits => 1,  agent_visits => 0, days => 1, last => '2026-10-19' },
] } } );
ok( !$r->{err}, 'the function runs' ) or diag $r->{err};
like( $r->{asked}[0], qr/action=analyse_visitors/, 'it asks analyse_visitors' );
like( $r->{asked}[0], qr/by_account=1/,            '...for the accounts' );
like( $r->{asked}[0], qr/window=30/,               '...over the 30 days the card names' );
ok( !$r->{hidden}, 'the card is shown' );
like( $r->{html}, qr{<td>alice</td><td>12</td><td>3</td><td>2026-10-20</td>}, 'a row per account: account, visits, days, last visit' );
unlike( $r->{html}, qr/<b>x<\/b>/, 'an account name is escaped' );
like( $r->{html}, qr/&lt;b&gt;x&lt;\/b&gt;&amp;/, '...not dropped' );

$r = run_card( { ok => JSON::PP::true, by_account => { accounts => [] } } );
ok( !$r->{hidden}, 'with no signed-in visits the card is shown' );
like( $r->{html}, qr/No signed-in visits recorded in the last 30 days\./, '...and says that, as a fact' );

$r = run_card( { ok => JSON::PP::false, error => 'forbidden' } );
ok( $r->{hidden}, 'a caller the call refuses (no analytics) never sees the card' );
is( $r->{html}, '', '...and nothing is drawn' );

done_testing();
