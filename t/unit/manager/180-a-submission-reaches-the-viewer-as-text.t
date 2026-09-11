#!/usr/bin/perl
# SM793: a stored submission reaches the operator's screen as text, with no
# escape in between to forget.
#
# The review found the viewer safe because every cell passed through esc() - one
# function, in the session with the most authority on the site - and the release
# manager ruled for the stronger shape: the table is built from DOM nodes and
# textContent, and each button's action is a closure rather than an attribute
# holding a quoted value. So this drives the viewer's own code in node against a
# small recording DOM, with a payload in every place a value can land, and asks
# the property directly: did any of it become markup?
use strict;
use warnings;
use Test::More;
use File::Temp ();
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use PageScript qw(extract_function page_source);

chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
plan skip_all => 'node not installed' unless length $node && -x $node;

my $page = page_source( repo_root() . '/starter/manager/plugin-config.md' );
my $defs = join "\n", map { extract_function( $page, $_, 'plugin-config.md' ) }
    qw(subsNode subsMessage setSubsBody showSubmissionTable);
my $dir = File::Temp->newdir;    # scratch for the node script, not a docroot

my $dom = <<'JS';
// A recording DOM: enough of the API for the viewer, and a note of every time
// anything is handed a string of HTML.
var HTML_WRITES = [];
function Node(tag) { this.tag = tag; this.children = []; this.attrs = {}; this.handlers = {}; this._text = null; }
Node.prototype.appendChild = function (c) {
  if (c.tag === '#fragment') { c.children.forEach(function (k) { this.children.push(k); }, this); }
  else this.children.push(c);
  return c;
};
Node.prototype.setAttribute = function (k, v) { this.attrs[k] = String(v); };
Node.prototype.addEventListener = function (ev, fn) { this.handlers[ev] = fn; };
Object.defineProperty(Node.prototype, 'textContent', {
  get: function () { return this._text != null ? this._text : this.children.map(function (c) { return c.textContent; }).join(''); },
  set: function (v) { this.children = []; this._text = String(v); }
});
Object.defineProperty(Node.prototype, 'innerHTML', {
  set: function (v) { HTML_WRITES.push(String(v)); },
  get: function () { return ''; }
});
var BODY = new Node('div'), TITLE = new Node('strong');
var document = {
  createElement: function (t) { return new Node(t); },
  createTextNode: function (s) { var n = new Node('#text'); n._text = String(s); return n; },
  createDocumentFragment: function () { return new Node('#fragment'); },
  getElementById: function (id) { return id === 'subs-modal-body' ? BODY : id === 'subs-modal-title' ? TITLE : null; }
};
function walk(n, fn) { fn(n); n.children.forEach(function (c) { walk(c, fn); }); }
var API = '/api', subsFilter = 'all', subsCurrent = null, subsLoaded = null;
var CALLS = [];
function deleteSubmissionRow() { CALLS.push(['delete'].concat([].slice.call(arguments))); }
function confirmSubmissionRow() { CALLS.push(['confirm'].concat([].slice.call(arguments))); }
function setSubsFilter() {} function downloadSubmissionsCsv() {} function bulkDeleteSubmissions() {} function subsToggleAll() {}
JS

my $drive = <<'JS';
var P = '<img src=x onerror="alert(1)">\'";&lt;';
var DATA = { ok: 1, total: 1, shown: 1,
  columns: ['name', P, '_quarantined', '_spam_reason'],
  rows: [ { _id: "id'" + P, name: P, _quarantined: true, _spam_reason: P } ] };
DATA.rows[0][P] = 'in a column whose NAME is the payload';
var fetch = function () { return Promise.resolve({ json: function () { return Promise.resolve(DATA); } }); };
showSubmissionTable('lazysite/forms/submissions/x.jsonl', 'form' + P);
setTimeout(function () {
  var tags = {}, texts = [], titles = [], values = [];
  walk(BODY, function (n) {
    tags[n.tag] = 1;
    if (n._text != null) texts.push(n._text);
    if (n.title != null) titles.push(n.title);
    if (n.value != null) values.push(n.value);
  });
  var del = null;
  walk(BODY, function (n) { if (n.tag === 'button' && n._text === 'Delete') del = n; });
  if (del) del.handlers.click();
  console.log(JSON.stringify({ tags: Object.keys(tags), texts: texts, titles: titles, values: values,
    html: HTML_WRITES, calls: CALLS, title: TITLE.textContent, payload: P }));
}, 0);
JS

open my $o, '>', "$dir/t.js" or die $!;
print {$o} $dom, $defs, "\n", $drive;
close $o;
my $raw = `\Q$node\E \Q$dir/t.js\E 2>&1`;
my $r   = eval { decode_json($raw) } or BAIL_OUT("the viewer did not run: $raw");
my $P   = $r->{payload};

ok( ( grep { $_ eq 'table' } @{ $r->{tags} } ), 'the canary: the viewer drew its table' );
ok( !( grep { $_ eq 'img' } @{ $r->{tags} } ),  'no stored value became an element' );
is_deeply( [ grep { index( $_, $P ) >= 0 } @{ $r->{html} } ], [],
    'and none was ever handed to innerHTML' );

ok( ( grep { $_ eq $P } @{ $r->{texts} } ), 'a value is shown as exactly the text that was stored' );
ok( ( grep { $_ eq $P } @{ $r->{texts} } ) && ( grep { $_ eq 'in a column whose NAME is the payload' } @{ $r->{texts} } ),
    'a column named by the payload is drawn too' );
ok( ( grep { $_ eq $P } @{ $r->{titles} } ), 'the spam reason is a title property, not an attribute string' );
ok( ( grep { $_ eq "id'$P" } @{ $r->{values} } ), 'the row id is the checkbox value as stored' );
is( $r->{title}, "Submissions: form$P", 'the heading takes the form name as text' );

is_deeply( $r->{calls}, [ [ 'delete', 'lazysite/forms/submissions/x.jsonl', "id'$P", "form$P" ] ],
    'Delete acts on the exact row id, a quote and all - a closure, not an attribute to quote' );

done_testing();
