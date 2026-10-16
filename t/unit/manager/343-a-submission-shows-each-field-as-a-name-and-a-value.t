#!/usr/bin/perl
# SM1096: the submission view shows each field as its name and its value, apart.
#
# The 0.15.5 test plan (2026-10-16): "The submission view runs a field's name
# and value together ("messagezz55 F9 event 2"), so the body does not read as a
# body." render() put the name and the value in two bare <span>s, which sit side
# by side with nothing between them, and a value's newlines collapsed to spaces
# because nothing told the browser to keep them (SM928: a body keeps its
# newlines, t/unit/lib/58).
#
# Held here, driven through the page's own render() in node:
#
# - each field is its own element holding a name node and a value node, the
#   name carrying the label class and the value the value class
# - the name is the field's name alone and the value is the value alone
# - a multi-line value reaches the DOM with its newlines, as text
# - markup in a value is text, never parsed (innerHTML is never written)
# - and the stylesheets that ship give the value pre-wrap, so the newlines show
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

my $page = PageScript::page_source("$root/starter/manager/submission.md");
my $fns  = join "\n", map { PageScript::extract_function( $page, $_ ) } qw(node render);
my $dir  = File::Temp->newdir;

my $dom = <<'JS';
function El(tag) {
  this.tag = tag; this.className = ''; this.children = []; this.href = '';
  this._text = ''; this.innerHTMLWritten = false;
}
Object.defineProperty(El.prototype, 'textContent', {
  get: function () { return this._text; },
  set: function (v) { this._text = String(v); this.children = []; }
});
Object.defineProperty(El.prototype, 'innerHTML', {
  set: function () { this.innerHTMLWritten = true; }
});
El.prototype.appendChild = function (c) { this.children.push(c); return c; };
var els = { 'sub-title': new El('span'), 'sub-body': new El('div'), 'sub-actions': new El('div') };
var document = {
  getElementById: function (id) { return els[id]; },
  createElement: function (t) { return new El(t); }
};
function walk(n, f) { f(n); n.children.forEach(function (k) { walk(k, f); }); }
function out(o) { console.log(JSON.stringify(o)); }
JS

my $drive = <<'JS';
var body = "zz55 F9\nevent 2\n\nsecond paragraph";
var markup = '<img src=x onerror=alert(1)>';
render({ file: 'lazysite/forms/submissions/contact.jsonl',
         fields: ['name', 'message'],
         record: { _form: 'contact', name: markup, message: body } });
var fields = els['sub-body'].children[0].children;
var written = false;
walk(els['sub-body'], function (n) { if (n.innerHTMLWritten) written = true; });
out({ count: fields.length,
      shape: fields.map(function (f) {
        return { kids: f.children.map(function (c) { return { cls: c.className, text: c.textContent }; }) };
      }),
      innerHTML: written });
JS

open my $fh, '>', "$dir/t.js" or die "t.js: $!";
print {$fh} $dom, $fns, "\n", $drive;
close $fh;
my $raw = `\Q$node\E \Q$dir/t.js\E 2>&1`;
require JSON::PP;
my $r = eval { JSON::PP::decode_json($raw) };
diag "node said: $raw" unless $r;
$r ||= { count => 0, shape => [] };

is $r->{count}, 2, 'one element per field';
my ( $name, $msg ) = @{ $r->{shape} };

is scalar @{ $msg->{kids} || [] }, 2, 'a field is a name node and a value node, nothing run together';
my ( $mn, $mv ) = @{ $msg->{kids} || [] };
is $mn->{text}, 'message', 'the name node is the field name alone';
is $mv->{text}, "zz55 F9\nevent 2\n\nsecond paragraph",
    'the value node is the value alone, newlines kept as text';
like $mn->{cls}, qr/\bmg-field-name\b/,  'the name is a label';
like $mv->{cls}, qr/\bmg-field-value\b/, 'the value is a value';
isnt $mn->{cls}, $mv->{cls}, 'and the two are visibly different things';

is $name->{kids}[1]{text}, '<img src=x onerror=alert(1)>', 'markup in a value is kept as text';
ok !$r->{innerHTML}, 'and nothing is written through innerHTML';

for my $style (qw(classic modern accessible)) {
    my $css = do {
        local ( @ARGV, $/ ) = ("$root/starter/lazysite/manager/assets/manager-$style.css");
        <>;
    };
    like $css, qr/\.mg-field-value\s*\{[^}]*white-space:\s*pre-wrap/s,
        "$style: a value keeps its newlines when drawn";
    like $css, qr/\.mg-field-name\s*\{/, "$style: the label has a style";
}

done_testing;
