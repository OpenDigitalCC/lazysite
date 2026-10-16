#!/usr/bin/perl
# SM1101: the Site URL field offers "Use this address".
#
# The release manager, 2026-10-16: "offer a 'set this' option, which sets it to
# the current ${REQUEST_SCHEME}://${SERVER_NAME}". site_url's default is that
# template, worked out per request - so a notice the scheduler or the CLI sends
# has no SERVER_NAME and its links fall back to bare paths. The button fills the
# field with the address the page is open at; Save writes it.
#
# What this holds, driving the Config page's own functions in node:
#
# - a field marked set_current carries the button, and a field without it does
#   not
# - the button fills the field with the page's origin and marks the form
#   unsaved, and does not save
# - the page's own SITE_SCHEMA marks site_url so
use strict;
use warnings;
use Test::More;
use File::Temp ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use PageScript ();
use JSON::PP   ();

my $root = repo_root();
my $page = PageScript::page_source("$root/starter/manager/config.md");

like( $page, qr/key: 'site_url'.{0,200}?set_current: true/s, 'the page marks site_url set_current' );

chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
SKIP: {
    skip 'node not installed', 1 unless length $node && -x $node;
    my $fns = join "\n",
        map { PageScript::extract_function( $page, $_ ) } qw(esc renderSiteForm setCurrentAddress);
    my $dir = File::Temp->newdir;
    open my $fh, '>', "$dir/t.js" or die $!;
    print {$fh} <<'JS', $fns, <<'JS2';
var location = { protocol: 'https:', host: 'www.example.test:8443' };
var SERVICE_PRESETS = {}, availableLayouts = [], dirty = 0, saved = 0;
function markSiteDirty() { dirty++; }
function saveSiteSettings() { saved++; }
var SITE_SCHEMA = [
  { key: 'site_url', label: 'Site URL', type: 'text', set_current: true },
  { key: 'site_name', label: 'Site name', type: 'text' }
];
var field = { value: '${REQUEST_SCHEME}://${SERVER_NAME}' };
var document = { getElementById: function (id) {
  return id === 'site-form' ? { elements: { site_url: field } } : null; } };
JS
var html = renderSiteForm({});
var marks = (html.match(/Use this address/g) || []).length;
setCurrentAddress('site_url');
console.log(JSON.stringify({ marks: marks,
  onSiteUrl: /name="site_url"[^>]*>\s*<button[^>]*setCurrentAddress\('site_url'\)/.test(html),
  value: field.value, dirty: dirty, saved: saved }));
JS2
    close $fh;
    my $out = `\Q$node\E \Q$dir/t.js\E 2>&1`;
    my $r = eval { JSON::PP::decode_json( ( $out =~ /(\{.*\})/s )[0] ) };
    subtest 'the button fills the field and does not save' => sub {
        ok( $r, 'node ran' ) or return diag $out;
        is( $r->{marks}, 1, 'one button: on the marked field only' );
        ok( $r->{onSiteUrl}, 'beside the Site URL input' );
        is( $r->{value}, 'https://www.example.test:8443', 'fills the page origin' );
        is( $r->{dirty}, 1, 'marks the form unsaved' );
        is( $r->{saved}, 0, 'and saves nothing' );
    };
}

done_testing;
