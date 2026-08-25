#!/usr/bin/perl
# SM580: the operator read an audit line - an MCP actor writing a file - and
# looked for that actor in Active sessions, where it was not.
#
# It could not be: the session registry is written ONLY by the cookie login
# path, so a bearer or OAuth partner is absent by construction and its absence
# is evidence of nothing. On an instance whose partners are agents, most of the
# acting principals are the ones that card cannot show.
#
# Two things were wrong and both are answered here. The sessions card claimed
# to list everyone signed in, without saying it meant browsers. And the keys
# card said a key was "in use" - a historical fact - without saying WHEN, which
# is the one thing that lets an audit line be attached to a principal.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $page = repo_root() . '/starter/manager/sessions.md';
plan skip_all => "no $page" unless -f $page;
my $src = do { open my $fh, '<', $page or die $!; local $/; <$fh> };

# --- what the sessions card claims -----------------------------------------
like( $src, qr/signed in <strong>through a browser<\/strong>/,
    'the sessions card says it lists BROWSER sign-ins, not everyone' );
like( $src, qr/does <strong>not<\/strong>\s*\n?\s*appear here/,
    'and says in as many words that an agent does not appear in it' );
like( $src, qr/Active keys/,
    'and points at the card that does show them' );

# --- what the keys card renders --------------------------------------------
chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
SKIP: {
    skip 'node not installed', 3 unless length $node && -x $node;
    my ($fn) = $src =~ /(function renderKeys\s*\(.*?\n\}\n)/s;
    ok( $fn, 'the page carries renderKeys' ) or skip 'no renderKeys', 2;

    my $dir = tempdir( CLEANUP => 1 );
    open my $js, '>', "$dir/t.js" or die $!;
    print {$js} <<"JS";
var boxes = {};
function escHtml(x) { return String(x == null ? '' : x); }
var document = { getElementById: function (id) {
    boxes[id] = boxes[id] || { innerHTML: '' };
    return boxes[id];
} };
function revokeKey() {}

$fn

var now = Math.floor(Date.now() / 1000);
renderKeys({ ok: true, keys: [
  { user: 'agent', channels: ['mcp'], issued_at: now - 7200,
    used_at: now - 120, in_use: true },
  { user: 'fresh', channels: ['api'], issued_at: now - 60,
    used_at: 0, in_use: false }
] });
console.log(JSON.stringify({ html: boxes['key-list'].innerHTML }));
JS
    close $js;
    my $raw = `\Q$node\E \Q$dir/t.js\E 2>&1`;
    my $got = eval { require JSON::PP; JSON::PP::decode_json($raw) };
    ok( $got, 'renderKeys ran' ) or do { diag($raw); skip 'did not run', 1 };

    like( $got->{html}, qr/in use.*last used/s,
        'a key in use says WHEN it was last used - the fact that ties an '
            . 'audit line to a principal' );
}

done_testing();
