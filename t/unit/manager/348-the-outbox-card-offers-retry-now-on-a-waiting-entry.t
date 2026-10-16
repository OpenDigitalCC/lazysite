#!/usr/bin/perl
# SM1107 (0.15.6 test plan, U8): THE OUTBOX CARD OFFERS "RETRY NOW" ON A WAITING
# ENTRY, AND NOWHERE ELSE.
#
# "No way to retry an outbox entry now ... A 'retry now' for the operator would
# make a mail fix testable without posting fresh events." The Handlers page's
# Notification outbox card puts a Retry now button on an entry that is retrying
# (in backoff after a failed send) - not on a queued one, which is due already,
# not on a sent or failed one, which a retry would not send. Pressing it posts
# notify-outbox-retry with the entry's id, says what happened, and reloads the
# card. Driven through the page's own JavaScript in node.
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

my $page = PageScript::page_source("$root/starter/manager/handlers.md");
my $fns  = join "\n", map { PageScript::extract_function( $page, $_ ) } qw(renderOutbox retryOutbox);
my $dir  = File::Temp->newdir;

my $dom = <<'JS';
function escHtml(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;'); }
function whenText(t) { return 't' + t; }
function chev() { return '<chev>'; }
var list = { innerHTML: '' };
var document = { getElementById: function (id) { return id === 'outbox-list' ? list : null; } };
var OUTBOX = { entries: [], held: [] };
var said = [], reloaded = 0, posted = [], reply;
function showStatus(m, err) { said.push({ m: m, err: !!err }); }
function loadOutbox() { reloaded++; }
function post(action, body) { posted.push({ action: action, body: body }); return Promise.resolve(reply); }
function out(o) { console.log(JSON.stringify(o)); }
JS

my $drive = <<'JS';
(async function () {
  OUTBOX = { held: [], entries: [
    { id: 'aaaa', rule: 'r', state: 'retrying', created: 1, attempts: 2, last_error: 'connection refused' },
    { id: 'bbbb', rule: 'r', state: 'queued',   created: 2, attempts: 0 },
    { id: 'cccc', rule: 'r', state: 'sent',     created: 3, attempts: 0 },
    { id: 'dddd', rule: 'r', state: 'failed',   created: 4, attempts: 5, reason: 'gave up' } ] };
  renderOutbox(0);
  var html = list.innerHTML;
  var buttons = (html.match(/retryOutbox\('([^']*)'\)/g) || []);
  out({ step: 'render', buttons: buttons, impact: /data-impact="change"/.test(html) });

  reply = { ok: true, retried: 1 };
  retryOutbox('aaaa');
  await new Promise(function (r) { setTimeout(r, 10); });
  out({ step: 'retried', posted: posted[0], said: said[0], reloaded: reloaded });

  said = []; reloaded = 0;
  reply = { ok: false, error: 'the notification job is running; try again in a moment' };
  retryOutbox('aaaa');
  await new Promise(function (r) { setTimeout(r, 10); });
  out({ step: 'refused', said: said[0], reloaded: reloaded });
})();
JS

open my $fh, '>', "$dir/t.js" or die "t.js: $!";
print {$fh} $dom, $fns, "\n", $drive;
close $fh;
my @lines = split /\n/, `\Q$node\E \Q$dir/t.js\E 2>&1`;
require JSON::PP;
my %r = map { my $o = eval { JSON::PP::decode_json($_) }; $o ? ( $o->{step} => $o ) : () } @lines;
diag "node said: @lines" unless keys %r == 3;

subtest 'only a retrying entry carries the button' => sub {
    my $s = $r{render} or return fail('no result');
    is_deeply( $s->{buttons}, ["retryOutbox('aaaa')"], 'one button, on the retrying entry' );
    ok( $s->{impact}, 'declared as a change' );
};

subtest 'pressing it posts the entry id, says so, and reloads' => sub {
    my $s = $r{retried} or return fail('no result');
    is( $s->{posted}{action}, 'notify-outbox-retry', 'the action' );
    is_deeply( $s->{posted}{body}, { id => 'aaaa' }, 'with the entry\'s id' );
    like( $s->{said}{m}, qr/Due now/, 'and the status says it is due' );
    is( $s->{reloaded}, 1, 'the card reloads' );
};

subtest 'a refusal is shown as an error and nothing reloads' => sub {
    my $s = $r{refused} or return fail('no result');
    ok( $s->{said}{err}, 'an error' );
    like( $s->{said}{m}, qr/job is running/, 'with the server\'s sentence' );
    is( $s->{reloaded}, 0, 'no reload' );
};

done_testing;
