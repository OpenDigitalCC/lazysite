#!/usr/bin/perl
# SM1138 (slice A of SM1134): the Address profiles page, driven through its own
# JavaScript in node.
#
# What this holds:
#   - buildBody drops blank rows, trims, keeps the notes, and refuses (without
#     asking the server) a bad name, a note with no address and a duplicate; it
#     sends the name and entries the server would accept, and NO kind (SM1343: a
#     profile has none, and the server refuses one sent)
#   - renderProfiles shows an operator the Edit and Delete controls and anyone
#     else the profiles with none, and puts a name or a note on the page as text,
#     never as markup
#   - saveProfile asks the server with the body buildBody made, and sends nothing
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

my $page = PageScript::page_source("$root/starter/manager/address-profiles.md");
my $fns  = join "\n",
    map { PageScript::extract_function( $page, $_ ) }
    qw(node fail profileSummary buildBody renderProfiles addRow editorRows saveProfile);
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
var els = { profiles: new El('div'), 'new-btn': new El('button'), 'entry-rows': new El('div'),
  'profile-name': new El('input'), editor: new El('div'), 'editor-title': new El('span') };
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
function loadProfiles() {}
function out(o) { console.log(JSON.stringify(o)); }
function labels(box) { var l = []; walk(box, function (n) { if (n.tag === 'button') l.push(n.textContent); }); return l; }
function allText(box) { var t = []; walk(box, function (n) { if (n.textContent) t.push(n.textContent); }); return t.join(' | '); }
var profiles = {}, canEdit = false, editing = '';
JS

my $drive = <<'JS';
(async function () {
  out({ step: 'summary',
    one: profileSummary({ entries: [{}], updated_by: 'sjm' }),
    two: profileSummary({ entries: [{}, {}] }) });

  var rows = [ { cidr: ' 203.0.113.0/24 ', note: ' HQ ' }, { cidr: '', note: '' }, { cidr: '198.51.100.7', note: '' } ];
  out({ step: 'build', good: buildBody(' office ', rows),
    badName: buildBody('Office', rows), emptyName: buildBody('', rows),
    longName: buildBody(new Array(66).join('a'), rows),
    noteOnly: buildBody('office', [{ cidr: '', note: 'orphan' }]),
    dup: buildBody('office', [{ cidr: '10.0.0.1', note: '' }, { cidr: '10.0.0.1', note: 'again' }]),
    none: buildBody('office', []) });

  var d = { ok: 1, can_edit: 1, profiles: [
    { name: 'office', entries: [{ cidr: '203.0.113.0/24', note: '<b>HQ</b>' }], updated_by: 'op' },
    { name: 'blocked', entries: [] } ] };
  renderProfiles(d);
  out({ step: 'operator', buttons: labels(els.profiles), newHidden: els['new-btn'].hidden, text: allText(els.profiles) });
  d.can_edit = 0;
  renderProfiles(d);
  out({ step: 'viewer', buttons: labels(els.profiles), newHidden: els['new-btn'].hidden, text: allText(els.profiles) });
  renderProfiles({ ok: 1, can_edit: 1, profiles: [] });
  out({ step: 'empty', text: allText(els.profiles) });

  // saveProfile: a bad name asks nothing; a good profile posts what buildBody made.
  els['profile-name'].value = 'Bad Name';
  els['entry-rows'].children = [];
  addRow('10.0.0.0/8', 'lan');
  addRow('', '');
  reply = function () { return Promise.resolve({ json: function () { return Promise.resolve({ ok: 1 }); } }); };
  saveProfile();
  out({ step: 'refused', sent: sent.length, warned: warned.slice() });
  els['profile-name'].value = 'lan';
  saveProfile();
  await new Promise(function (r) { setTimeout(r, 10); });
  out({ step: 'posted', sent: sent.length, url: sent[0] && sent[0].url, body: sent[0] && JSON.parse(sent[0].body) });
  reply = function () { return Promise.resolve({ json: function () { return Promise.resolve({ ok: 0, error: 'Only the operator changes address profiles.' }); } }); };
  warned = [];
  saveProfile();
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

subtest 'a profile is summarised plainly, with no kind' => sub {
    my $s = $r{summary} or return fail('no result');
    is $s->{one}, '1 entry, last changed by sjm', 'singular, with who';
    is $s->{two}, '2 entries', 'plural, no author';
};

subtest 'buildBody sends only what the server would accept' => sub {
    my $s = $r{build} or return fail('no result');
    ok $s->{good}{ok}, 'a good profile builds';
    is_deeply $s->{good}{body},
        { name => 'office', entries => [ { cidr => '203.0.113.0/24', note => 'HQ' }, { cidr => '198.51.100.7', note => '' } ] },
        'trimmed, the blank row dropped, notes kept, and no kind sent';
    ok !$s->{badName}{ok} && $s->{badName}{error} =~ /a-z, 0-9/, 'a capital in a name is refused, saying what a name is';
    ok !$s->{emptyName}{ok}, 'an empty name is refused';
    ok !$s->{longName}{ok}, 'a 65-character name is refused';
    ok !$s->{noteOnly}{ok} && $s->{noteOnly}{error} =~ /note and no address/, 'a note with no address is refused';
    ok !$s->{dup}{ok} && $s->{dup}{error} =~ /10\.0\.0\.1 is listed twice/, 'a duplicate is refused, naming it';
    ok $s->{none}{ok} && @{ $s->{none}{body}{entries} } == 0, 'a profile with no entries is allowed';
};

subtest 'the operator is shown controls, a viewer is not, and text stays text' => sub {
    my $o = $r{operator} or return fail('no result');
    is_deeply $o->{buttons}, [ 'Edit', 'Delete', 'Edit', 'Delete' ], 'Edit and Delete on each profile';
    ok !$o->{newHidden}, 'New profile is offered';
    like $o->{text}, qr/office.*1 entry, last changed by op.*203\.0\.113\.0\/24 - <b>HQ<\/b>/s,
        'a note with markup is on the page as the characters typed';
    my $v = $r{viewer} or return fail('no result');
    is_deeply $v->{buttons}, [], 'a viewer has no buttons on the rows';
    ok $v->{newHidden}, '...and no New profile';
    like $v->{text}, qr/office/, '...but sees the profiles';
    like $r{empty}{text}, qr/There are no address profiles/, 'an empty store says so';
};

subtest 'saveProfile asks the server only with a body it built' => sub {
    my $s = $r{refused} or return fail('no result');
    is $s->{sent}, 0, 'a bad name sends nothing';
    like $s->{warned}[0], qr/1 to 64 characters/, 'and says why';
    my $p = $r{posted} or return fail('no result');
    is $p->{sent}, 1, 'a good one sends once';
    like $p->{url}, qr/action=address-profile-set\z/, 'to address-profile-set';
    is_deeply $p->{body}, { name => 'lan', entries => [ { cidr => '10.0.0.0/8', note => 'lan' } ] },
        'with the editor\'s rows (the blank one dropped)';
    like $r{'server-refusal'}{warned}[0], qr/Only the operator changes address profiles/, 'the server\'s sentence is shown as it came';
};

done_testing;
