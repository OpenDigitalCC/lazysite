#!/usr/bin/perl
# SM849: the page editor had no way into the page's history.
#
# The history already existed per file - Files' row panel offers View, Diff and
# Restore - so what was missing was a ROUTE, not a feature. The editor now
# offers History when content history is on, and it lands on Files' own panel
# for that file: the list page holding it, its row open, its History open. One
# implementation of the panel, so the two cannot drift.
#
# Offered only when it can answer: history off, or a new file with no versions
# yet, offers nothing - a button that opens onto "not enabled" is SM222's
# switched-off extension offering what it cannot do.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use PageScript ();

my $root = repo_root();
chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
plan skip_all => 'node not installed' unless length $node && -x $node;

my $edit  = PageScript::page_source("$root/starter/manager/edit.md");
my $files = PageScript::page_source("$root/starter/manager/files.md");
my $dir   = tempdir( CLEANUP => 1 );

sub run_js {
    my ($js) = @_;
    open my $o, '>', "$dir/t.js" or die $!;
    print {$o} $js;
    close $o;
    my $out = `\Q$node\E \Q$dir/t.js\E 2>&1`;
    chomp $out;
    return $out;
}

# --- the editor offers it, and only when it can answer -----------------------
my $offer = PageScript::extract_function( $edit, 'edOfferHistory', 'edit.md' );
my $esc   = PageScript::extract_function( $edit, 'esc',            'edit.md' );

sub editor {
    my (%o) = @_;
    my $enabled = $o{enabled} ? 'true' : 'false';
    my $new     = $o{new}     ? 'true' : 'false';
    return run_js(<<"JS");
var API = '/api', filePath = '$o{path}', isNew = $new;
var backFolder = filePath ? filePath.replace(/\\/?[^\\/]*\$/, '') : '';
var asked = 0, inserted = '';
var view = { insertAdjacentHTML: function (w, h) { inserted = h; } };
var document = { getElementById: function (id) { return id === 'ed-view-link' ? view : null; } };
function fetch() { asked++; return Promise.resolve({ json: function () { return { ok: 1, enabled: $enabled }; } }); }
$esc
$offer
edOfferHistory();
setTimeout(function () { console.log(asked + '|' + inserted); }, 0);
JS
}

{
    my ( $asked, $html ) = split /\|/, editor( path => '/docs/a b.md', enabled => 1 ), 2;
    like( $html, qr/>History<\/a>/, 'with history on, the editor offers History' );
    my ($href) = $html =~ /href="([^"]*)"/;
    is( $href, '/manager/files?path=%2Fdocs&amp;history=%2Fdocs%2Fa%20b.md',
        'and it routes to Files, in the page\'s own folder, naming the page' );
}
{
    my ( $asked, $html ) = split /\|/, editor( path => '/docs/a.md', enabled => 0 ), 2;
    is( $html, '', 'with history off, nothing is offered' );
}
{
    my ( $asked, $html ) = split /\|/, editor( path => '/docs/new.md', enabled => 1, new => 1 ), 2;
    is( $html,  '',  'a new file - no versions yet - is offered nothing' );
    is( $asked, '0', 'and the editor does not even ask' );
}
like( $edit, qr/^loadFile\(\);\nedOfferHistory\(\);/m, 'the editor asks at boot' );

# --- Files opens the panel the link names ------------------------------------
my ($pending) = $files =~ /(var PENDING_HISTORY = \(function\(\) \{.*?\n\}\)\(\);)/s;
ok( $pending, 'Files reads the history= parameter' );
my $open = PageScript::extract_function( $files, 'openPendingHistory', 'files.md' );
like( PageScript::extract_function( $files, 'renderFiles', 'files.md' ),
    qr/openPendingHistory\(\)/, 'and consults it once the folder is listed' );

sub files_page {
    my (%o) = @_;
    my $git = $o{git} ? 'true' : 'false';
    return run_js(<<"JS");
var location = { search: '?path=%2Fdocs&history=' + encodeURIComponent('$o{want}') };
var GIT = { enabled: $git }, FILE_PAGE_SIZE = 50, filePage = 0, log = [];
var list = [];
for (var i = 0; i < 120; i++) list.push({ path: '/docs/f' + i + '.md' });
function filteredSortedFiles() { return list; }
function showStatus(m) { log.push('status:' + m); }
function paintFiles() { log.push('page:' + filePage); }
function togglePerms(el) { log.push('open:' + el.row); }
function toggleHistory(b) { log.push('history:' + b.row); }
function mkRow(p) {
  var r = { getAttribute: function () { return p; },
            querySelector: function () { return { row: p }; },
            nextElementSibling: { querySelector: function () { return { row: p }; } } };
  return r;
}
var document = { querySelectorAll: function () {
  var s = filePage * FILE_PAGE_SIZE, out = [];
  for (var i = s; i < Math.min(s + FILE_PAGE_SIZE, list.length); i++) out.push(mkRow(list[i].path));
  return out; } };
$pending
$open
openPendingHistory();
openPendingHistory();
console.log(log.join(','));
JS
}

is( files_page( want => '/docs/f75.md', git => 1 ),
    'page:1,open:/docs/f75.md,history:/docs/f75.md',
    'the list turns to the page holding the file, opens its row and its History - once' );
like( files_page( want => '/docs/elsewhere.md', git => 1 ),
    qr/^status:No history to open: \/docs\/elsewhere\.md is not in this folder\.$/,
    'a file not in the folder is said so, not silently ignored' );
like( files_page( want => '/docs/f3.md', git => 0 ),
    qr/^status:Content history is not enabled/,
    'history switched off since the link was made is said so' );

done_testing();
