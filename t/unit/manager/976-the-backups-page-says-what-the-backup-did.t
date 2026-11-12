#!/usr/bin/perl
# SM1446: THE BACKUPS PAGE SAYS WHAT THE BACKUP DID, AND SHOWS AN UNFINISHED ONE
# FOR WHAT IT IS.
#
# In the field the button returned to rest with nothing on the page: the outcome
# was only a toast, and a request the server stopped waiting for answered with an
# error page that is not JSON, which the page dropped - no name, no refusal, and
# no new list until a manual reload. Driven through the page's own JavaScript in
# node:
#   - a finished backup: its name stays beside the button, and the list is read
#     again;
#   - a refusal: its reason stays beside the button, and the list is read again;
#   - an answer that is not JSON (HTTP 504): the page says the server stopped
#     waiting and that the list shows the backup when it has finished, or as
#     unfinished - and reads the list again;
#   - the listing's `unfinished` entries are shown apart, by name and time, each
#     with a Delete that sends the delete for its kind; none, and the note is
#     hidden.
#
# With the old page (no outcome line, no reload on failure, no renderUnfinished)
# these fail.
use strict;
use warnings;
use Test::More;
use File::Temp ();
use JSON::PP   ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root run_child);
use PageScript ();

my $root = repo_root();
my ($node) = grep { -x } map { "$_/node" } split /:/, $ENV{PATH} // '';
($node) = grep { -x } map { "$_/nodejs" } split /:/, $ENV{PATH} // '' unless $node;
plan skip_all => 'node not installed' unless $node;

my $page = PageScript::page_source("$root/starter/manager/backups.md");
like( $page, qr/id="content-outcome"/, 'the content card has an outcome line' );
like( $page, qr/id="full-outcome"/,    'and so does the full-system card' );
like( $page, qr/id="unfinished"[^>]*hidden/, 'the unfinished note starts hidden' );

my $fns = join "\n", map { PageScript::extract_function( $page, $_ ) }
    qw(escHtml fmtDate _create renderUnfinished deleteUnfinished);

my $dom = <<'JS';
function El() { this.textContent = ''; this.innerHTML = ''; this.hidden = true; }
var els = { 'full-outcome': new El(), 'content-outcome': new El(), unfinished: new El(), 'unfinished-list': new El() };
var document = { getElementById: function (id) { return els[id] || null; } };
var API = '/api', loaded = 0, toasts = [], sent = [], reply;
function loadBackups() { loaded++; }
function showStatus(m, e) { toasts.push([m, !!e]); }
function confirm() { return true; }
var window = { confirm: confirm };
function fetch(url, opt) { sent.push({ url: url, body: opt.body || null }); return reply(); }
function answer(status, text) {
  reply = function () { return Promise.resolve({ status: status,
    text: function () { return Promise.resolve(text); },
    json: function () { return Promise.resolve(JSON.parse(text)); } }); };
}
function tick() { return new Promise(function (r) { setTimeout(r, 10); }); }
function out(o) { console.log(JSON.stringify(o)); }
JS

my $drive = <<'JS';
(async function () {
  var btn = { disabled: false };
  answer(200, JSON.stringify({ ok: 1, name: 'lazysite-full-20261112T065507Z.tar.gz' }));
  _create(btn, '&scope=full', 'Full-system backup created: ', 'full-outcome');
  await tick();
  out({ step: 'done', text: els['full-outcome'].textContent, loaded: loaded, disabled: btn.disabled, url: sent[0].url });

  answer(200, JSON.stringify({ ok: 0, error: 'Backup failed: tar exited 2' }));
  _create(btn, '', 'Backup created: ', 'content-outcome');
  await tick();
  out({ step: 'refused', text: els['content-outcome'].textContent, loaded: loaded, disabled: btn.disabled });

  answer(504, '<html><body>504 Gateway Time-out</body></html>');
  _create(btn, '&scope=full', 'Full-system backup created: ', 'full-outcome');
  await tick();
  out({ step: 'no-answer', text: els['full-outcome'].textContent, loaded: loaded, disabled: btn.disabled,
        toast: toasts[toasts.length - 1] });

  renderUnfinished([{ name: 'lazysite-full-20261112T065507Z.tar.gz', mtime: 1794466507, kind: 'full' },
                    { name: 'lazysite-site-shop.example-20261112T070000Z.tar.gz', mtime: 1794466800, kind: 'site' }]);
  out({ step: 'listed', hidden: els.unfinished.hidden, html: els['unfinished-list'].innerHTML });

  sent = [];
  answer(200, JSON.stringify({ ok: 1 }));
  deleteUnfinished('lazysite-full-20261112T065507Z.tar.gz', null);
  await tick();
  deleteUnfinished('lazysite-site-shop.example-20261112T070000Z.tar.gz', null);
  await tick();
  out({ step: 'deleted', sent: sent });

  renderUnfinished([]);
  out({ step: 'none', hidden: els.unfinished.hidden });
})();
JS

my $dir = File::Temp->newdir;
open my $fh, '>', "$dir/t.js" or die "t.js: $!";
print {$fh} $dom, $fns, "\n", $drive;
close $fh;
my $run   = run_child( [ $node, "$dir/t.js" ], stderr => 'merge' );
my @lines = split /\n/, $run->{out};
my %r     = map { my $o = eval { JSON::PP::decode_json($_) }; $o ? ( $o->{step} => $o ) : () } @lines;
diag "node said: @lines" unless keys %r == 6;

subtest 'a finished backup: its name stays, and the list is read again' => sub {
    my $s = $r{done} or return fail('no result');
    is( $s->{text}, 'Full-system backup created: lazysite-full-20261112T065507Z.tar.gz', 'the name beside the button' );
    is( $s->{loaded}, 1, 'the list is read again' );
    ok( !$s->{disabled}, 'the button is back at rest' );
    like( $s->{url}, qr/action=backup-create&scope=full\z/, 'it asked for a full backup' );
};

subtest 'a refusal: its reason stays, and the list is read again' => sub {
    my $s = $r{refused} or return fail('no result');
    is( $s->{text}, 'Backup failed: tar exited 2', 'the reason beside the button' );
    is( $s->{loaded}, 2, 'the list is read again after a refusal too' );
};

subtest 'no answer: the page says so, and reads the list again' => sub {
    my $s = $r{'no-answer'} or return fail('no result');
    like( $s->{text}, qr/\ANo answer from the backup \(HTTP 504\): the server stopped waiting for it\. It may still finish; the list shows it when it has, or as unfinished\.\z/,
        'what happened, beside the button' );
    is( $s->{loaded}, 3, 'and the list is read again' );
    ok( !$s->{disabled}, 'the button is back at rest' );
    ok( $s->{toast}[1], 'shown as a failure' );
};

subtest 'unfinished backups are shown apart, each with a delete for its kind' => sub {
    my $s = $r{listed} or return fail('no result');
    ok( !$s->{hidden}, 'the note is shown' );
    like( $s->{html}, qr/lazysite-full-20261112T065507Z\.tar\.gz.*unfinished.*2026-11-12 06:55 UTC/s, 'by name and time' );
    like( $s->{html}, qr/deleteUnfinished\('lazysite-full-20261112T065507Z\.tar\.gz'/, 'with a Delete' );
    my $del = $r{deleted} or return fail('no delete result');
    is( scalar @{ $del->{sent} }, 2, 'two deletes sent' );
    like( $del->{sent}[0]{url}, qr/action=backup-delete\z/, 'a backup by backup-delete' );
    like( $del->{sent}[1]{url}, qr/action=site-backup-delete\z/, 'a site package by site-backup-delete' );
    is_deeply( JSON::PP::decode_json( $del->{sent}[0]{body} ), { name => 'lazysite-full-20261112T065507Z.tar.gz' },
        'naming the file' );
    ok( $r{none}{hidden}, 'and with none, the note is hidden' );
};

done_testing();
