#!/usr/bin/perl
# n812 (ruling 234, replacing SM1141's t/unit/manager/361): A PROFILE A RULE STILL
# NAMES CANNOT BE DELETED, AND THE ADDRESS PROFILES PAGE HAS NO "DELETE ANYWAY".
#
# Before, the page offered the operator "Delete anyway" for a profile the server
# refused as in-use, and sent force: true after a second confirmation. Address
# lists are predefined and selectable only: a profile in use may be changed and
# may not be deleted. Driven through the page's own JavaScript in node:
#   - a delete the server refuses as in-use shows the server's sentence (where the
#     profile is named) and sends no force
#   - the note offers Close and nothing that deletes; the page carries no force
#     control or force field at all
#   - the same for a viewer who is not the operator (the server refuses a write)
#
# With the old page (forceDelete, body.force) the source assertions fail.
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
unlike( $page, qr/force|anyway/i, 'the page carries no force control, field or wording' );

my $fns = join "\n",
    map { PageScript::extract_function( $page, $_ ) }
    qw(fail deleteProfile showInUse hideInUse sendDelete);
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
function loadProfiles() { loaded++; }
function answerWith(o) { reply = function () { return Promise.resolve({ json: function () { return Promise.resolve(o); } }); }; }
function out(o) { console.log(JSON.stringify(o)); }
function tick() { return new Promise(function (r) { setTimeout(r, 10); }); }
var canEdit = true, editing = '', inUse = '';
var IN_USE = { ok: 0, kind: 'in-use', error: "Address profile 'office' is still named by page members.md; group g-ops." };
JS

my $drive = <<'JS';
(async function () {
  answerWith(IN_USE);
  deleteProfile('office');
  await tick();
  out({ step: 'refused', sent: sent.slice(), shown: !els['in-use'].hidden, text: els['in-use-text'].textContent,
    warned: warned.slice(), asked: asked.length });

  hideInUse();
  out({ step: 'closed', shown: !els['in-use'].hidden, sent: sent.length });

  canEdit = false;
  answerWith(IN_USE);
  deleteProfile('office');
  await tick();
  out({ step: 'viewer', sent: sent.length, text: els['in-use-text'].textContent });
})();
JS

open my $fh, '>', "$dir/t.js" or die "t.js: $!";
print {$fh} $dom, $fns, "\n", $drive;
close $fh;
my @lines = split /\n/, `\Q$node\E \Q$dir/t.js\E 2>&1`;
require JSON::PP;
my %r = map { my $o = eval { JSON::PP::decode_json($_) }; $o ? ( $o->{step} => $o ) : () } @lines;
diag "node said: @lines" unless keys %r == 3;

subtest 'an in-use refusal is shown with where, and sends no force' => sub {
    my $s = $r{refused} or return fail('no result');
    is( scalar @{ $s->{sent} }, 1, 'one call' );
    like( $s->{sent}[0]{url}, qr/action=address-profile-delete\z/, 'to address-profile-delete' );
    is_deeply( $s->{sent}[0]{body}, { name => 'office' }, 'with the name alone' );
    ok( $s->{shown}, 'the in-use note is shown' );
    like( $s->{text}, qr/still named by page members\.md; group g-ops/, 'saying where, in the server\'s words' );
    is_deeply( $s->{warned}, [], 'and it is not shown as a failure' );
    is( $s->{asked}, 1, 'the ordinary delete asked once, and nothing asks again' );
};

subtest 'Close puts the note away and sends nothing' => sub {
    my $s = $r{closed} or return fail('no result');
    ok( !$s->{shown}, 'the note is put away' );
    is( $s->{sent}, 1, 'and nothing more was sent' );
};

subtest 'a viewer sees the same refusal' => sub {
    my $s = $r{viewer} or return fail('no result');
    like( $s->{text}, qr/still named by/, 'the refusal is shown' );
    is( $s->{sent}, 2, 'after one more plain delete' );
};

done_testing;
