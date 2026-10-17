#!/usr/bin/perl
# SM1138 (slice A of SM1134): the Address lists page, driven through its own
# JavaScript in node.
#
# What this holds:
#   - buildBody drops blank rows, trims, keeps the notes, and refuses (without
#     asking the server) a bad name, a missing kind, a note with no address and
#     a duplicate; it sends the name the server would accept
#   - renderLists shows an operator the Edit and Delete controls and anyone else
#     the lists with none, and puts a name or a note on the page as text, never
#     as markup
#   - saveList asks the server with the body buildBody made, and sends nothing
#     when buildBody refuses
use strict;
use warnings;
use Test::More;
use File::Temp ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use PageScript ();

my $root = repo_root();
chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
plan skip_all => 'node not installed' unless length $node && -x $node;

my $page = PageScript::page_source("$root/starter/manager/address-lists.md");
my $fns  = join "\n",
    map { PageScript::extract_function( $page, $_ ) }
    qw(node fail listSummary buildBody renderLists addRow editorRows saveList);
my $dir = File::Temp->newdir;

my $dom = <<'JS';
function El(tag) {
  this.tag = tag; this.className = ''; this.children = []; this.parentNode = null;
  this._text = ''; this.attrs = {}; this.hidden = false; this.value = ''; this.listeners = {};
}
// As a browser has it: assigning textContent replaces the children.
Object.defineProperty(El.prototype, 'textContent', {
  get: function () { return this._text; },
  set: function (v) { this._text = String(v); this.children = []; }
});
El.prototype.appendChild = function (c) { c.parentNode = this; this.children.push(c); return c; };
El.prototype.removeChild = function (c) { this.children = this.children.filter(function (x) { return x !== c; }); c.parentNode = null; };
El.prototype.setAttribute = function (k, v) { this.attrs[k] = v; };
El.prototype.addEventListener = function (e, f) { this.listeners[e] = f; };
Object.defineProperty(El.prototype, 'innerHTML', { set: function () { throw new Error('innerHTML is never used for operator text'); } });
function walk(n, f) { f(n); n.children.forEach(function (c) { walk(c, f); }); }
var els = { lists: new El('div'), 'new-btn': new El('button'), 'entry-rows': new El('div'),
  'list-name': new El('input'), 'list-kind': new El('select'), editor: new El('div'), 'editor-title': new El('span') };
var document = {
  getElementById: function (id) { return els[id] || null; },
  createElement: function (t) { return new El(t); },
  createTextNode: function (t) { var e = new El('#text'); e.textContent = t; return e; },
  querySelectorAll: function (sel) {
    var cls = sel.replace(/.*\./, ''), out = [];
    walk(els['entry-rows'], function (n) { if (n.className.split(/\s+/).indexOf(cls) >= 0) out.push(n); });
    return out;
  }
};
El.prototype.querySelector = function (sel) {
  var cls = sel.replace(/^\./, ''), hit = null;
  walk(this, function (n) { if (!hit && n !== this && n.className.split(/\s+/).indexOf(cls) >= 0) hit = n; });
  return hit;
};
var warned = [], sent = [], reply;
function mgShowWarning(m) { warned.push(m); }
function mgClearWarning() {}
function confirm() { return true; }
var API = '/api';
function fetch(url, opt) { sent.push({ url: url, body: opt && opt.body }); return reply(); }
function loadLists() {}
function out(o) { console.log(JSON.stringify(o)); }
function labels(box) { var l = []; walk(box, function (n) { if (n.tag === 'button') l.push(n.textContent); }); return l; }
function allText(box) { var t = []; walk(box, function (n) { if (n.textContent) t.push(n.textContent); }); return t.join(' | '); }
var lists = {}, canEdit = false, editing = '';
JS

my $drive = <<'JS';
(async function () {
  out({ step: 'summary',
    one: listSummary({ kind: 'allow', entries: [{}], updated_by: 'sjm' }),
    two: listSummary({ kind: 'deny', entries: [{}, {}] }) });

  var rows = [ { cidr: ' 203.0.113.0/24 ', note: ' HQ ' }, { cidr: '', note: '' }, { cidr: '198.51.100.7', note: '' } ];
  out({ step: 'build', good: buildBody(' office ', 'allow', rows),
    badName: buildBody('Office', 'allow', rows), emptyName: buildBody('', 'allow', rows),
    longName: buildBody(new Array(66).join('a'), 'allow', rows),
    badKind: buildBody('office', 'maybe', rows),
    noteOnly: buildBody('office', 'allow', [{ cidr: '', note: 'orphan' }]),
    dup: buildBody('office', 'allow', [{ cidr: '10.0.0.1', note: '' }, { cidr: '10.0.0.1', note: 'again' }]),
    none: buildBody('office', 'deny', []) });

  var d = { ok: 1, can_edit: 1, lists: [
    { name: 'office', kind: 'allow', entries: [{ cidr: '203.0.113.0/24', note: '<b>HQ</b>' }], updated_by: 'op' },
    { name: 'blocked', kind: 'deny', entries: [] } ] };
  renderLists(d);
  out({ step: 'operator', buttons: labels(els.lists), newHidden: els['new-btn'].hidden, text: allText(els.lists) });
  d.can_edit = 0;
  renderLists(d);
  out({ step: 'viewer', buttons: labels(els.lists), newHidden: els['new-btn'].hidden, text: allText(els.lists) });
  renderLists({ ok: 1, can_edit: 1, lists: [] });
  out({ step: 'empty', text: allText(els.lists) });

  // saveList: a bad name asks nothing; a good list posts what buildBody made.
  els['list-name'].value = 'Bad Name'; els['list-kind'].value = 'allow';
  els['entry-rows'].children = [];
  addRow('10.0.0.0/8', 'lan');
  addRow('', '');
  reply = function () { return Promise.resolve({ json: function () { return Promise.resolve({ ok: 1 }); } }); };
  saveList();
  out({ step: 'refused', sent: sent.length, warned: warned.slice() });
  els['list-name'].value = 'lan';
  saveList();
  await new Promise(function (r) { setTimeout(r, 10); });
  out({ step: 'posted', sent: sent.length, url: sent[0] && sent[0].url, body: sent[0] && JSON.parse(sent[0].body) });
  reply = function () { return Promise.resolve({ json: function () { return Promise.resolve({ ok: 0, error: 'Only the operator changes address lists.' }); } }); };
  warned = [];
  saveList();
  await new Promise(function (r) { setTimeout(r, 10); });
  out({ step: 'server-refusal', warned: warned.slice() });
})();
JS

open my $fh, '>', "$dir/t.js" or die "t.js: $!";
print {$fh} $dom, $fns, "\n", $drive;
close $fh;
my @lines = split /\n/, `\Q$node\E \Q$dir/t.js\E 2>&1`;
require JSON::PP;
my %r = map { my $o = eval { JSON::PP::decode_json($_) }; $o ? ( $o->{step} => $o ) : () } @lines;
diag "node said: @lines" unless keys %r == 8;

subtest 'a list is summarised plainly' => sub {
    my $s = $r{summary} or return fail('no result');
    is $s->{one}, 'allow list, 1 entry, last changed by sjm', 'singular, with who';
    is $s->{two}, 'deny list, 2 entries', 'plural, no author';
};

subtest 'buildBody sends only what the server would accept' => sub {
    my $s = $r{build} or return fail('no result');
    ok $s->{good}{ok}, 'a good list builds';
    is_deeply $s->{good}{body},
        { name => 'office', kind => 'allow', entries => [ { cidr => '203.0.113.0/24', note => 'HQ' }, { cidr => '198.51.100.7', note => '' } ] },
        'trimmed, the blank row dropped, notes kept';
    ok !$s->{badName}{ok} && $s->{badName}{error} =~ /a-z, 0-9/, 'a capital in a name is refused, saying what a name is';
    ok !$s->{emptyName}{ok}, 'an empty name is refused';
    ok !$s->{longName}{ok}, 'a 65-character name is refused';
    ok !$s->{badKind}{ok} && $s->{badKind}{error} =~ /allow or deny/, 'a kind that is neither is refused';
    ok !$s->{noteOnly}{ok} && $s->{noteOnly}{error} =~ /note and no address/, 'a note with no address is refused';
    ok !$s->{dup}{ok} && $s->{dup}{error} =~ /10\.0\.0\.1 is listed twice/, 'a duplicate is refused, naming it';
    ok $s->{none}{ok} && @{ $s->{none}{body}{entries} } == 0, 'a list with no entries is allowed';
};

subtest 'the operator is shown controls, a viewer is not, and text stays text' => sub {
    my $o = $r{operator} or return fail('no result');
    is_deeply $o->{buttons}, [ 'Edit', 'Delete', 'Edit', 'Delete' ], 'Edit and Delete on each list';
    ok !$o->{newHidden}, 'New list is offered';
    like $o->{text}, qr/office.*allow list, 1 entry, last changed by op.*203\.0\.113\.0\/24 - <b>HQ<\/b>/s,
        'a note with markup is on the page as the characters typed';
    my $v = $r{viewer} or return fail('no result');
    is_deeply $v->{buttons}, [], 'a viewer has no buttons on the rows';
    ok $v->{newHidden}, '...and no New list';
    like $v->{text}, qr/office/, '...but sees the lists';
    like $r{empty}{text}, qr/There are no address lists/, 'an empty store says so';
};

subtest 'saveList asks the server only with a body it built' => sub {
    my $s = $r{refused} or return fail('no result');
    is $s->{sent}, 0, 'a bad name sends nothing';
    like $s->{warned}[0], qr/1 to 64 characters/, 'and says why';
    my $p = $r{posted} or return fail('no result');
    is $p->{sent}, 1, 'a good one sends once';
    like $p->{url}, qr/action=address-list-set\z/, 'to address-list-set';
    is_deeply $p->{body}, { name => 'lan', kind => 'allow', entries => [ { cidr => '10.0.0.0/8', note => 'lan' } ] },
        'with the editor\'s rows (the blank one dropped)';
    like $r{'server-refusal'}{warned}[0], qr/Only the operator changes address lists/, 'the server\'s sentence is shown as it came';
};

done_testing;
