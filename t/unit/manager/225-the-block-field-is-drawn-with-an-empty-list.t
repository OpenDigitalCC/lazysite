#!/usr/bin/perl
# RULED 2026-10-11 "Always show the field": the bad-URL blocker's card in the
# manager (Extensions, Blocked addresses) draws the "Block this address" field
# whether or not any address is blocked. It was drawn only when the list
# already held one, so on a site with none the operator had no way to block
# the first address by hand (found running TEST-PLAN-0154 R14). The empty list
# keeps its sentence, "No addresses are currently blocked."
#
# The page's own loadBlocked() is run under node against both answers of
# bad-url-blocks - an empty list and a list of one - with fetch stood in.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use JSON::PP   qw(decode_json);
use TestHelper qw(repo_root site_tempdir);

my $page = repo_root() . '/starter/manager/plugin-config.md';
plan skip_all => "no $page" unless -f $page;
my $src = do { open my $fh, '<', $page or die "$page: $!"; local $/; <$fh> };

chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
plan skip_all => 'node not installed' unless length $node && -x $node;

my ($fn) = $src =~ /(function loadBlocked\s*\(.*?\n\}\n)/s;
ok( $fn, 'the page carries loadBlocked' ) or BAIL_OUT('no loadBlocked to run');

my $dir = site_tempdir();

# Runs loadBlocked() with bad-url-blocks answering $answer (JSON text) and
# returns what it drew into the card's body.
sub drawn {
    my ($answer) = @_;
    open my $js, '>', "$dir/t.js" or die "$dir/t.js: $!";
    print {$js} <<"JS";
var API = '/cgi-bin/lazysite-manager-api.pl';
var body = { innerHTML: '', textContent: '' };
var document = { getElementById: function (id) {
    return id === 'blocked-body' ? body : null;
} };
function esc(x) { return String(x == null ? '' : x)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
function fetch(url) {
    if (url.indexOf('action=bad-url-blocks') < 0) throw new Error('asked ' + url);
    return Promise.resolve({ json: function () { return $answer; } });
}

$fn

loadBlocked();
setTimeout(function () {
    console.log(JSON.stringify({ html: body.innerHTML, text: body.textContent }));
}, 0);
JS
    close $js;
    my $raw = `\Q$node\E \Q$dir/t.js\E 2>&1`;
    my $got = eval { decode_json($raw) };
    diag("node said: $raw") unless $got;
    return $got || { html => '', text => $raw };
}

my $field = qr/id="block-add-ip".*Block this address/s;

# --- no address blocked ---------------------------------------------------
my $none = drawn('{ "ok": true, "blocks": {} }');
like( $none->{html}, $field,
    'with no address blocked, the card offers the field to block one' );
like( $none->{html}, qr/No addresses are currently blocked\./,
    'and still says that none is blocked' );
unlike( $none->{html}, qr/<table/, 'and draws no empty table' );

# --- one address blocked ----------------------------------------------------
my $one = drawn('{ "ok": true, "blocks": { "203.0.113.9": { "count": 4, "since": 1760000000 } } }');
like( $one->{html}, $field, 'with an address blocked, the field is there too' );
like( $one->{html}, qr/<code>203\.0\.113\.9<\/code>.*Unblock/s,
    'and the address is listed with its Unblock button' );
unlike( $one->{html}, qr/No addresses are currently blocked/,
    'and the card does not say that none is blocked' );

# --- the list cannot be read ------------------------------------------------
my $err = drawn('{ "ok": false, "error": "Not permitted." }');
like( $err->{html}, qr/Not permitted\./, 'a refusal is shown as it came' );

done_testing();
