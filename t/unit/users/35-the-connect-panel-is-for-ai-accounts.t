#!/usr/bin/perl
# SM596: "Connect an AI assistant" appeared on every account, including ones
# this same sheet titles "human".
#
# SM455 opened the panel to every account deliberately: the channel that makes
# an account connectable comes from GROUP MEMBERSHIP, set on another page, so
# gating on it meant an operator set an AI up, saw no picker, and could not tell
# a stale page from a failed action. The fix keeps that whole - an AI account
# with no channel yet still gets the picker - and stops only the case the
# operator reported.
#
# THE JAVASCRIPT IS RUN, NOT READ, for the reason t/unit/users/29 gives: a test
# that greps the source would pass on any string carrying the right words, and
# the defect is entirely in what the guard EVALUATES to.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $page = repo_root() . '/starter/manager/users.md';
plan skip_all => "no $page" unless -f $page;
chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
plan skip_all => 'node not installed' unless length $node && -x $node;

my $src = do { open my $fh, '<', $page or die $!; local $/; <$fh> };
my ($fn) = $src =~ /(function accountSettingsHtml\s*\(.*?\n\}\n)/s;
ok( $fn, 'the page carries accountSettingsHtml' ) or do { done_testing(); exit };

my $dir = tempdir( CLEANUP => 1 );
open my $js, '>', "$dir/t.js" or die $!;
print {$js} <<"JS";
// Stubs for what the function reaches at RENDER time. Each returns something
// shaped like the real thing; none of them decides what is under test.
function escHtml(x) { return String(x == null ? '' : x); }
function sec(title, body) { return '<section data-sec="' + title + '">' + body + '</section>'; }
function groupsForUser() { return []; }
function orderedParentOptions() { return []; }
function parentOfSettings() { return ''; }
function descendantsOf() { return []; }
function lineageText() { return ''; }
function expiryDate() { return ''; }
var DAV_BASE = 'https://example.test/dav/';
var allGroups = {}, uiGroups = {}, rowsByUser = {};
var amOperator = false;

$fn

var cases = {
  // `ui` unset is the human default the page applies everywhere else.
  human_default: { },
  human_explicit: { ui: true },
  ai:             { ui: false },
  ai_with_mcp:    { ui: false, mcp: true },
  // A human account that ALSO holds a remote channel genuinely needs a token,
  // and the WebDAV block points at this panel to get one.
  human_with_api: { ui: true, api: true },
  human_webdav:   { ui: true, webdav: true }
};
var out = {};
for (var k in cases) {
  var html = accountSettingsHtml({ user: 'u_' + k, settings: cases[k] });
  out[k] = {
    panel: html.indexOf('Connect an AI assistant') !== -1,
    points_at_panel: html.indexOf('generate one under') !== -1
  };
}
console.log(JSON.stringify(out));
JS
close $js;

my $raw = `\Q$node\E \Q$dir/t.js\E 2>&1`;
my $got = eval { require JSON::PP; JSON::PP::decode_json($raw) };
ok( $got, 'accountSettingsHtml ran' ) or do { diag($raw); done_testing(); exit };

ok( !$got->{human_default}{panel},
    'a human account (ui unset - the default) is not offered an AI connector' );
ok( !$got->{human_explicit}{panel},
    'a human account (ui explicitly on) is not offered an AI connector' );
ok( !$got->{human_webdav}{panel},
    'a human account using WebDAV is not offered one either' );

ok( $got->{ai}{panel},
    'SM455 stays whole: an AI account with NO channel yet still gets the picker' );
ok( $got->{ai_with_mcp}{panel}, 'an AI account holding mcp gets it' );
ok( $got->{human_with_api}{panel},
    'a human account holding api gets it - it needs a token, whatever else it is' );

# The WebDAV block tells the reader to "generate one under Connect an AI
# assistant below". Where the panel is gone, that sentence must go with it.
ok( !$got->{human_webdav}{points_at_panel},
    'with the panel hidden, nothing points the reader at it' );

done_testing();
