#!/usr/bin/perl
# SM1141 (slice D of SM1134), finished when the slices were stacked: THE ADDRESS
# LISTS PAGE OFFERS THE OPERATOR "DELETE ANYWAY" FOR A LIST A RULE STILL NAMES.
#
# SM1141's filing left open: "The manager's Address lists page shows the refusal
# text but has no "delete anyway" control; the API takes `force`." Driven through
# the page's own JavaScript in node:
#   - a delete the server refuses as in-use shows the server's sentence (where the
#     list is named) with "Delete anyway", and sends no force of its own
#   - "Delete anyway" confirms again, then sends force: true for that list; a
#     declined confirmation sends nothing
#   - a viewer who is not the operator is never offered it
#   - "Keep the list" puts it away and leaves nothing to force
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
    qw(fail deleteList showInUse hideInUse forceDelete sendDelete);
my $dir = File::Temp->newdir;

my $dom = <<'JS';
function El(tag) { this.tag = tag; this.hidden = false; this._text = ''; }
Object.defineProperty(El.prototype, 'textContent', {
  get: function () { return this._text; }, set: function (v) { this._text = String(v); } });
Object.defineProperty(El.prototype, 'innerHTML', { set: function () { throw new Error('innerHTML is never used for server text'); } });
var els = { 'in-use': new El('div'), 'in-use-text': new El('p'), editor: new El('div') };
els['in-use'].hidden = true;
var document = { getElementById: function (id) { return els[id] || null; } };
var warned = [], sent = [], asked = [], reply, answer = true, loaded = 0;
function mgShowWarning(m) { warned.push(m); }
function confirm(m) { asked.push(m); return answer; }
var API = '/api';
function fetch(url, opt) { sent.push({ url: url, body: JSON.parse(opt.body) }); return reply(); }
function loadLists() { loaded++; }
function answerWith(o) { reply = function () { return Promise.resolve({ json: function () { return Promise.resolve(o); } }); }; }
function out(o) { console.log(JSON.stringify(o)); }
function tick() { return new Promise(function (r) { setTimeout(r, 10); }); }
var canEdit = true, editing = '', inUse = '';
var IN_USE = { ok: 0, kind: 'in-use', error: "Address list 'office' is still named by page members.md; group g-ops." };
JS

my $drive = <<'JS';
(async function () {
  answerWith(IN_USE);
  deleteList('office');
  await tick();
  out({ step: 'refused', sent: sent.slice(), shown: !els['in-use'].hidden, text: els['in-use-text'].textContent,
    warned: warned.slice(), asked: asked.length });

  answer = false;
  forceDelete();
  await tick();
  out({ step: 'declined', sent: sent.length, asked: asked.length, shown: !els['in-use'].hidden });

  answer = true;
  answerWith({ ok: 1, name: 'office', change: 'deleted (1 entries, allow, forced); still named by page members.md' });
  forceDelete();
  await tick();
  out({ step: 'forced', sent: sent.slice(1), asked: asked.slice(1), shown: !els['in-use'].hidden, loaded: loaded,
    left: inUse });

  // A forced call the server still refuses is shown as a refusal, not offered again.
  answerWith(IN_USE);
  showInUse('office', IN_USE.error);
  warned = [];
  forceDelete();
  await tick();
  out({ step: 'forced-refused', warned: warned.slice() });

  // Keep the list: put away, nothing left to force.
  showInUse('office', IN_USE.error);
  hideInUse();
  var before = sent.length;
  forceDelete();
  await tick();
  out({ step: 'kept', shown: !els['in-use'].hidden, sent: sent.length - before });

  // A viewer is never offered it.
  canEdit = false;
  els['in-use'].hidden = true;
  answerWith(IN_USE);
  deleteList('office');
  await tick();
  out({ step: 'viewer', shown: !els['in-use'].hidden });
})();
JS

open my $fh, '>', "$dir/t.js" or die "t.js: $!";
print {$fh} $dom, $fns, "\n", $drive;
close $fh;
my @lines = split /\n/, `\Q$node\E \Q$dir/t.js\E 2>&1`;
require JSON::PP;
my %r = map { my $o = eval { JSON::PP::decode_json($_) }; $o ? ( $o->{step} => $o ) : () } @lines;
diag "node said: @lines" unless keys %r == 6;

subtest 'an in-use refusal is shown with Delete anyway, and sends no force' => sub {
    my $s = $r{refused} or return fail('no result');
    is( scalar @{ $s->{sent} }, 1, 'one call' );
    like( $s->{sent}[0]{url}, qr/action=address-list-delete\z/, 'to address-list-delete' );
    is_deeply( $s->{sent}[0]{body}, { name => 'office' }, 'without force' );
    ok( $s->{shown}, 'the in-use note with Delete anyway is shown' );
    like( $s->{text}, qr/still named by page members\.md; group g-ops/, 'saying where, in the server\'s words' );
    is_deeply( $s->{warned}, [], 'and it is not shown as a failure' );
    is( $s->{asked}, 1, 'the ordinary delete asked once' );
};

subtest 'Delete anyway confirms again, and only then sends force' => sub {
    my $n = $r{declined} or return fail('no result');
    is( $n->{sent}, 1, 'a declined confirmation sends nothing' );
    is( $n->{asked}, 2, '...after asking' );
    ok( $n->{shown}, '...and the note stays' );
    my $f = $r{forced} or return fail('no result');
    is( scalar @{ $f->{sent} }, 1, 'an accepted one sends once' );
    is_deeply( $f->{sent}[0]{body}, { name => 'office', force => JSON::PP::true() }, 'force: true, for that list' );
    like( $f->{asked}[-1], qr/anyway\?.*admit nobody/s, 'the confirmation says what forcing does' );
    ok( !$f->{shown}, 'the note is put away when it is deleted' );
    is( $f->{loaded}, 1, 'and the lists are read again' );
    is( $f->{left}, '', 'nothing is left to force' );
};

subtest 'a forced call the server refuses is a refusal' => sub {
    my $s = $r{'forced-refused'} or return fail('no result');
    like( $s->{warned}[0] // '', qr/still named by/, 'shown as the server said it' );
};

subtest 'Keep the list leaves nothing to force' => sub {
    my $s = $r{kept} or return fail('no result');
    ok( !$s->{shown}, 'the note is put away' );
    is( $s->{sent}, 0, 'and Delete anyway then sends nothing' );
};

subtest 'a viewer is not offered Delete anyway' => sub {
    my $s = $r{viewer} or return fail('no result');
    ok( !$s->{shown}, 'the note stays hidden for a viewer' );
};

done_testing;
