#!/usr/bin/perl
# SM1221: the manager pages' shared fetch wrapper (layout.tt) reads the API's
# 401 - now the signed-out answer - as a lapsed sign-in: it raises the "sign in
# again" warning once, with a Refresh button. A 400, 403, 503 and 200 do not.
# Driven in node: the wrapper's own source, over a stub window and fetch.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use File::Temp ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use PageScript ();

my $root = repo_root();
chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
plan skip_all => 'node not installed' unless length $node && -x $node;

my $src = PageScript::page_source("$root/starter/lazysite/manager/layout.tt");
my ($wrapper) = $src =~ /(\(function\(\)\{\n    var MGR_API.*?\n  \}\)\(\);)/s;
die "the layout's fetch wrapper was not found\n" unless defined $wrapper;

my $dir = File::Temp->newdir;
my $js  = <<'JS';
var warned = [], buttons = 0, status = 200;
var bar = { appendChild: function () { buttons++; } };
var document = {
  getElementById: function (id) { return id === 'mg-warning-bar' ? bar : null; },
  createElement: function () { return {}; }
};
var window = {
  mgShowWarning: function (m) { warned.push(m); },
  fetch: function () { return Promise.resolve({ status: status, ok: status < 400,
    headers: { get: function () { return 'application/json'; } } }); }
};
var location = { reload: function () {} };
var fetch = window.fetch;
function Headers() { this.has = function () { return false; }; this.set = function () {}; }
JS
my $drive = <<'JS';
(async function () {
  var out = {};
  for (var s of [200, 400, 403, 503]) {
    status = s; warned = [];
    await window.fetch('/cgi-bin/lazysite-manager-api.pl?action=whoami');
    out['s' + s] = warned.length;
  }
  status = 401; warned = [];
  await window.fetch('/cgi-bin/lazysite-manager-api.pl?action=whoami');
  await window.fetch('/cgi-bin/lazysite-manager-api.pl?action=whoami');
  out.s401 = warned.length;
  out.text = warned[0] || '';
  console.log(JSON.stringify(out));
})();
JS
my $file = "$dir/h.js";
open my $fh, '>', $file or die $!;
print {$fh} "$js\n$wrapper\n$drive\n";
close $fh;
my $o = `$node $file 2>&1`;
my $r = eval { decode_json( ( split /\n/, $o )[-1] ) } or BAIL_OUT("node said: $o");
is( $r->{s401}, 1, 'a 401 raises the sign-in-again warning, once however many calls meet it' );
like( $r->{text}, qr/sign in again/, 'in words that say what to do' );
is( $r->{$_}, 0, "a $_ does not" ) for map { "s$_" } qw(200 400 403 503);
done_testing;
