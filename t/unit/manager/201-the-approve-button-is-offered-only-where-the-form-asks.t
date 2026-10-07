#!/usr/bin/perl
# SM858: the Submissions view offers Approve on a registration form's rows - and
# only there - and a stored value reaches the screen as text.
#
# Drives the viewer's own code in node against a recording DOM, as
# t/unit/manager/180 does (SM793's ruling: rows are DOM nodes and textContent,
# a button's action is a closure). The payload sits in the address field, in the
# account a row became and in who approved it - every new place a stored value
# can land - and the question is asked directly: did any of it become markup?
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
    qw(subsNode subsMessage setSubsBody showSubmissionTable approveSubmissionRow);
my $dir = File::Temp->newdir;    # scratch for the node script, not a docroot

my $dom = <<'JS';
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
var ASKED = [], POSTS = [], STATUS = [];
function mgConfirm(msg, o) { ASKED.push(msg); return { then: function (f) { f(true); } }; }
function showStatus(m) { STATUS.push(String(m)); }
function deleteSubmissionRow() {} function confirmSubmissionRow() {}
function setSubsFilter() {} function downloadSubmissionsCsv() {} function bulkDeleteSubmissions() {} function subsToggleAll() {}
JS

my $drive = <<'JS';
var P = '<img src=x onerror="alert(1)">\'";&lt;';
var MODE = process.argv[2];
var DATA = { ok: 1, total: 3, shown: 3,
  columns: ['name', 'email', '_quarantined', '_approved_account', '_approved_by'],
  rows: [
    { _id: 'r-open', name: 'open', email: P + '@example.org' },
    { _id: 'r-done', name: 'done', email: 'd@example.org', _approved_account: P, _approved_by: P },
    { _id: 'r-held', name: 'held', email: 'h@example.org', _quarantined: true }
  ] };
if (MODE === 'declared') DATA.account_email = 'email';
var fetch = function (url, o) {
  if (o && o.method === 'POST') POSTS.push({ url: url, body: o.body });
  return Promise.resolve({ json: function () { return Promise.resolve(DATA); } });
};
showSubmissionTable('lazysite/forms/submissions/register.jsonl', 'register');
setTimeout(function () {
  var tags = {}, texts = [], titles = [], approve = [], cols = [];
  walk(BODY, function (n) {
    tags[n.tag] = 1;
    if (n._text != null) texts.push(n._text);
    if (n.title != null) titles.push(n.title);
    if (n.tag === 'th' && n._text != null) cols.push(n._text);
  });
  walk(BODY, function (n) {
    if (n.tag !== 'tr') return;
    var b = null;
    walk(n, function (k) { if (k.tag === 'button' && k._text === 'Approve') b = k; });
    if (b) approve.push(n.children[2] ? n.children[2].textContent : '?');
    if (b && MODE === 'declared') b.handlers.click();
  });
  setTimeout(function () {
    console.log(JSON.stringify({ tags: Object.keys(tags), texts: texts, titles: titles, cols: cols,
      approve: approve, asked: ASKED, posts: POSTS, html: HTML_WRITES, payload: P }));
  }, 0);
}, 0);
JS

open my $o, '>', "$dir/t.js" or die $!;
print {$o} $dom, $defs, "\n", $drive;
close $o;

sub run_mode {
    my ($mode) = @_;
    my $raw = `\Q$node\E \Q$dir/t.js\E \Q$mode\E 2>&1`;
    return eval { decode_json($raw) } || BAIL_OUT("the viewer did not run: $raw");
}

my $r = run_mode('declared');
my $P = $r->{payload};
ok( ( grep { $_ eq 'table' } @{ $r->{tags} } ), 'the canary: the viewer drew its table' );
is_deeply( $r->{approve}, ['open'],
    'Approve is offered on the open row only - not the approved one, not the quarantined one' );
ok( !( grep { $_ eq 'img' } @{ $r->{tags} } ), 'no stored value became an element' );
is_deeply( [ grep { index( $_, $P ) >= 0 } @{ $r->{html} } ], [], 'and none was handed to innerHTML' );
ok( ( grep { $_ eq "account: $P" } @{ $r->{texts} } ), 'the account a row became is shown as text' );
ok( ( grep { index( $_, "by $P" ) >= 0 } @{ $r->{titles} } ), 'who approved it is a title property' );
ok( !( grep { /\A_approved/ } @{ $r->{cols} } ), 'the approval bookkeeping is not drawn as data columns' );
like( $r->{asked}[0] // '', qr/\Q$P\E\@example\.org/, 'the question names the address, as text' );
is( scalar @{ $r->{posts} }, 1, 'one approval was sent' );
is_deeply( decode_json( $r->{posts}[0]{body} // '{}' ),
    { file => 'lazysite/forms/submissions/register.jsonl', id => 'r-open' },
    'it sends the store and the row id and NOTHING ELSE - the server reads the address' );
like( $r->{posts}[0]{url} // '', qr/action=form-submission-approve\z/, 'to the approve action' );

my $u = run_mode('undeclared');
ok( ( grep { $_ eq 'table' } @{ $u->{tags} } ), 'the canary: the undeclared form drew its table' );
is_deeply( $u->{approve}, [], 'a form that does not declare account_email offers no Approve' );

done_testing();
