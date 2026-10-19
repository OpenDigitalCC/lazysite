#!/usr/bin/perl
# SM1192: the three pages where address rules are edited show the server's
# `proxy_warning` as text, and decide nothing themselves.
#   - Address lists: loadLists -> showProxyWarning(d.proxy_warning)
#   - Config: the config-read answer's proxy_warning
#   - Groups: the address-lists answer the group editor already fetches
# Each page has a #proxy-warning element: hidden when the answer carries none,
# shown with the server's sentence as text (never markup) when it does.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use File::Temp ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use PageScript ();

my $root = repo_root();
chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
plan skip_all => 'node not installed' unless length $node && -x $node;
my $dir = File::Temp->newdir;

my $dom = <<'JS';
function El(tag) { this.tag = tag; this.hidden = true; this._text = ''; }
Object.defineProperty(El.prototype, 'textContent', {
  get: function () { return this._text; }, set: function (v) { this._text = String(v); } });
Object.defineProperty(El.prototype, 'innerHTML', { set: function () { throw new Error('innerHTML is never used for server text'); } });
var els = { 'proxy-warning': new El('div') };
var document = { getElementById: function (id) { return els[id] || null; } };
function out(o) { console.log(JSON.stringify(o)); }
JS

my $drive = <<'JS';
out({ step: 'shown', fn: typeof showProxyWarning });
showProxyWarning('Every visitor reaches this site from 10.2.30.177, <b>x</b>');
out({ step: 'with', hidden: els['proxy-warning'].hidden, text: els['proxy-warning'].textContent });
showProxyWarning(undefined);
out({ step: 'without', hidden: els['proxy-warning'].hidden, text: els['proxy-warning'].textContent });
JS

for my $p (qw(address-lists config groups)) {
    my $src = PageScript::page_source("$root/starter/manager/$p.md");
    like( $src, qr/id="proxy-warning"/, "$p: the page has the warning element" );
    like( $src, qr/proxy_warning/, "$p: the page reads the server's answer" );
    my $fn = eval { PageScript::extract_function( $src, 'showProxyWarning' ) };
    ok( defined $fn && length $fn, "$p: showProxyWarning exists" ) or next;
    my $file = "$dir/$p.js";
    open my $fh, '>', $file or die $!;
    print {$fh} "$dom\n$fn\n$drive\n";
    close $fh;
    my @lines = map { decode_json($_) } split /\n/, `$node $file 2>&1`;
    my %by = map { $_->{step} => $_ } grep { ref eq 'HASH' && $_->{step} } @lines;
    ok( $by{with} && !$by{with}{hidden}, "$p: shown when the answer carries a warning" );
    is( $by{with}{text}, 'Every visitor reaches this site from 10.2.30.177, <b>x</b>', "$p: as text, not markup" );
    ok( $by{without} && $by{without}{hidden}, "$p: hidden when it does not" );
}

done_testing;
