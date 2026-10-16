#!/usr/bin/perl
# SM1084: a refused extension toggle says why AT THE ROW.
#
# The release manager, 2026-10-16, enabling the Odoo extension on a host
# without the OOM package: "the toggle just springs back - it should explain
# why it wont enable". The server did explain - SM472's sentence naming
# Odoo::Ops and its package came back in `error`, and the audit row carried
# `missing_deps: Odoo::Ops` (SM711). The page put that sentence in the status
# line at the TOP of the page, above the list, in the muted colour of a
# progress line. An operator toggling a row further down saw only the switch
# move back.
#
# What this holds, driven through the page's own JavaScript in node:
#
# - a refused enable puts the server's sentence under that extension's row, as
#   an alert, and the status line carries it styled as an error
# - the next toggle of the row clears the old refusal before it asks again
# - a toggle that cannot reach the server says so at the row as well
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

my $page = PageScript::page_source("$root/starter/manager/plugins.md");
my $fns  = join "\n",
    map { PageScript::extract_function( $page, $_ ) }
    qw(warn showRowRefusal clearRowRefusal togglePlugin);
my $dir = File::Temp->newdir;

# A stand-in DOM holding exactly what the four functions touch: the status
# line, and one extension row with its main column and its checkbox.
my $dom = <<'JS';
function El(cls) {
  this.className = cls || ''; this.children = []; this.parentNode = null;
  this.textContent = ''; this.style = {}; this.attrs = {};
  var self = this;
  this.classList = { toggle: function (c, on) {
    var l = self.className.split(/\s+/).filter(function (x) { return x && x !== c; });
    if (on) l.push(c); self.className = l.join(' ');
  }, contains: function (c) { return self.className.split(/\s+/).indexOf(c) >= 0; } };
}
El.prototype.appendChild = function (c) { c.parentNode = this; this.children.push(c); return c; };
El.prototype.removeChild = function (c) { this.children = this.children.filter(function (x) { return x !== c; }); c.parentNode = null; };
El.prototype.setAttribute = function (k, v) { this.attrs[k] = v; };
El.prototype.querySelector = function (sel) {
  var c = sel.replace(/^\./, ''), hit = null;
  (function walk(n) { n.children.forEach(function (k) {
    if (!hit && k.className.split(/\s+/).indexOf(c) >= 0) hit = k; if (!hit) walk(k); }); })(this);
  return hit;
};
El.prototype.closest = function (sel) {
  var c = sel.replace(/^\./, ''), n = this;
  while (n) { if (n.className.split(/\s+/).indexOf(c) >= 0) return n; n = n.parentNode; }
  return null;
};
var status = new El('mg-status');
var row = new El('mg-plugin-row'), ctl = row.appendChild(new El('mg-plugin-ctl')),
    main = row.appendChild(new El('mg-plugin-main')), input = ctl.appendChild(new El('mg-toggle'));
var document = {
  getElementById: function (id) { return id === 'plugin-status' ? status : null; },
  createElement: function () { return new El(''); }
};
var API = '/api', reloaded = 0;
function loadPluginRegistry() { reloaded++; }
var reply;
function fetch() { return reply(); }
function ok(v) { return Promise.resolve({ json: function () { return Promise.resolve(v); } }); }
function refusal() { var n = main.querySelector('.mg-plugin-refusal'); return n ? n.textContent : null; }
function out(o) { console.log(JSON.stringify(o)); }
JS

my $drive = <<'JS';
(async function () {
  var said = 'This plugin needs Odoo::Ops (Debian: odoo-oom) and they are not installed.';
  reply = function () { return ok({ ok: 0, kind: 'missing_deps', error: said }); };
  input.checked = true;
  togglePlugin(input, 'plugins/odoo.pl', 'Odoo');
  await new Promise(function (r) { setTimeout(r, 10); });
  var note = main.querySelector('.mg-plugin-refusal');
  out({ step: 'refused', checked: input.checked, row: refusal(),
        role: note && note.attrs.role, status: status.textContent,
        error: status.classList.contains('mg-status-error') });

  reply = function () { return new Promise(function () {}); };
  input.checked = true;
  togglePlugin(input, 'plugins/odoo.pl', 'Odoo');
  out({ step: 'retry', row: refusal() });

  reply = function () { return Promise.reject(new Error('network down')); };
  input.disabled = false; input.checked = true;
  togglePlugin(input, 'plugins/odoo.pl', 'Odoo');
  await new Promise(function (r) { setTimeout(r, 10); });
  out({ step: 'unreachable', row: refusal(), checked: input.checked });
})();
JS

open my $fh, '>', "$dir/t.js" or die "t.js: $!";
print {$fh} $dom, $fns, "\n", $drive;
close $fh;
my @lines = split /\n/, `\Q$node\E \Q$dir/t.js\E 2>&1`;
require JSON::PP;
my %r = map { my $o = eval { JSON::PP::decode_json($_) }; $o ? ( $o->{step} => $o ) : () } @lines;
diag "node said: @lines" unless keys %r == 3;

subtest 'a refused enable says why under its own row' => sub {
    my $s = $r{refused} or return fail('no result');
    ok !$s->{checked}, 'the switch goes back';
    like $s->{row}, qr/Failed to enable Odoo: This plugin needs Odoo::Ops/,
        'the row carries the server sentence, naming what is missing';
    is $s->{role}, 'alert', 'announced as an alert';
    like $s->{status}, qr/Odoo::Ops/, 'the status line says it too';
    ok $s->{error}, 'the status line is styled as an error, not a progress line';
};

subtest 'toggling again clears the old refusal first' => sub {
    my $s = $r{retry} or return fail('no result');
    is $s->{row}, undef, 'no stale refusal while the new request is out';
};

subtest 'an unreachable server is said at the row as well' => sub {
    my $s = $r{unreachable} or return fail('no result');
    like $s->{row}, qr/Error: network down/, 'the row says the request failed';
    ok !$s->{checked}, 'the switch goes back';
};

done_testing;
