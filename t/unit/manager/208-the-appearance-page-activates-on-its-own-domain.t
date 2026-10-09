#!/usr/bin/perl
# SM976 F4 (ruled 2026-10-09, "Activate on its domain"): for a manager confined
# to its own domains, the Appearance page's Activate binds the layout or theme to
# the manager's domain - theme-activate / layout-activate with host, which needs
# no domain-management permission - and with several domains it asks which. The
# operator's page is unchanged: no host, the instance, as before.
#
# Before, the page sent the instance-wide activation for everyone, and a
# confined manager met "changes the whole instance" (R1) for the only
# activation the page offered. themes-list-all names the manager's domains as
# `acts_on` (t/integration/116 holds the API side); this runs the page's own
# functions under node against stubbed fetch and dialogs.
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

my $src = PageScript::page_source("$root/starter/manager/appearance.md");
my $js  = join "\n", map { PageScript::extract_function( $src, $_, 'appearance.md' ) }
    qw(activationHost activateQuery renderActsOn activateThemeOnly activateLayout);

my $dir = tempdir( CLEANUP => 1 );
open my $o, '>', "$dir/run.js" or die $!;
print {$o} <<"JS";
var API = '/api';
var ACTS_ON = null;
var sent = [], said = [], asked = [], note = { hidden: true, textContent: '' };
var answer = null;
var document = { getElementById: function () { return note; } };
function fetch(url) { sent.push(url); return Promise.resolve({ json: function () { return { ok: 1 }; } }); }
function mgPrompt(msg, value) { asked.push(msg + ' [' + value + ']'); return Promise.resolve(answer); }
function mgConfirm(msg) { asked.push(msg); return Promise.resolve(true); }
function showStatus(msg, err) { said.push((err ? 'ERR ' : '') + msg); }
function loadAll() {}
$js
function flush() { return new Promise(function (r) { setImmediate(r); }); }
var out = {};
async function scene(name, acts, ans, fn) {
  ACTS_ON = acts; answer = ans; sent = []; said = []; asked = [];
  renderActsOn();
  fn();
  await flush(); await flush(); await flush();
  out[name] = { sent: sent, said: said, asked: asked, note: note.hidden ? null : note.textContent };
}
(async function () {
  await scene('operator theme', null, null, function () { activateThemeOnly('two'); });
  await scene('operator layout', null, null, function () { activateLayout('base'); });
  await scene('one domain theme', ['mine.example.org'], null, function () { activateThemeOnly('two'); });
  await scene('one domain layout', ['mine.example.org'], null, function () { activateLayout('base'); });
  await scene('two domains, chooses', ['a.example', 'b.example'], 'b.example', function () { activateThemeOnly('two'); });
  await scene('two domains, declines', ['a.example', 'b.example'], null, function () { activateThemeOnly('two'); });
  await scene('two domains, not one of them', ['a.example', 'b.example'], 'c.example', function () { activateThemeOnly('two'); });
  await scene('no domain', [], null, function () { activateThemeOnly('two'); });
  console.log(JSON.stringify(out));
})();
JS
close $o;
my $raw = `\Q$node\E \Q$dir/run.js\E 2>&1`;
require JSON::PP;
my $r = eval { JSON::PP->new->decode($raw) } or BAIL_OUT("node said: $raw");

is_deeply( $r->{'operator theme'}{sent}, ['/api?action=theme-activate&theme=two'],
    'the operator activates the instance\'s theme, as before - no host' );
is_deeply( $r->{'operator layout'}{sent}, ['/api?action=layout-activate&layout=base'], '...and layout' );
is( $r->{'operator theme'}{note}, undef, '...and is shown no note' );
is_deeply( $r->{'operator theme'}{asked}, [], '...nor asked which domain' );

is_deeply( $r->{'one domain theme'}{sent}, ['/api?action=theme-activate&theme=two&host=mine.example.org'],
    'a manager confined to one domain activates the theme on it' );
is_deeply( $r->{'one domain layout'}{sent}, ['/api?action=layout-activate&layout=base&host=mine.example.org'],
    '...and the layout' );
like( $r->{'one domain layout'}{asked}[0], qr/on mine\.example\.org\?/, '...the confirmation naming the domain' );
like( $r->{'one domain theme'}{said}[0], qr/activated on mine\.example\.org/, '...and so does the status' );
like( $r->{'one domain theme'}{note}, qr/You manage mine\.example\.org: Activate applies to that domain/,
    'the page says where Activate applies' );

like( $r->{'two domains, chooses'}{asked}[0], qr/which of your domains\? a\.example, b\.example \[a\.example\]/,
    'with two domains it asks which, offering the first' );
is_deeply( $r->{'two domains, chooses'}{sent}, ['/api?action=theme-activate&theme=two&host=b.example'],
    '...and activates on the one chosen' );
is_deeply( $r->{'two domains, declines'}{sent}, [], 'declining sends nothing' );
is_deeply( $r->{'two domains, not one of them'}{sent}, [], 'a name that is not one of its domains sends nothing' );
like( $r->{'two domains, not one of them'}{said}[0], qr/ERR .*"c\.example" is not one of your domains/, '...and says so' );
is_deeply( $r->{'no domain'}{sent}, [], 'a manager that reaches no domain sends nothing' );
like( $r->{'no domain'}{said}[0], qr/ERR .*reach no domain/, '...and is told why' );

# The Deactivate button is the instance's theme; it is not offered to a confined manager.
like( $src, qr/if \(!ACTS_ON\) html \+= '<button class="mg-btn mg-btn-sm" onclick="deactivateTheme\(\)">Deactivate<\/button>';/,
    'Deactivate is offered only to an unconfined caller' );
like( $src, qr/ACTS_ON = Array\.isArray\(ta\.acts_on\) \? ta\.acts_on : null;/,
    'the page reads acts_on from the themes-list-all it already loads' );

done_testing();
