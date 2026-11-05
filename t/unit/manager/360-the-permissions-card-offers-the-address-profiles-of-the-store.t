#!/usr/bin/perl
# SM1139 (slice B of SM1134), SM1344 (0.16.5, A-3): the Files page's permissions
# card limits a rule by ADDRESS PROFILE: one picker, a row per profile in the store,
# each chosen Allow, Deny or Not used, in place of SM1139's two kind-filtered
# pickers ("Only these addresses" / "Never these").
#
# Driven through the page's own JavaScript in node (PageScript), with a stand-in
# card:
#
# - the block is headed "Limited by address profile" and has one row per profile,
#   every profile offered (a profile has no kind, SM1343)
# - the profiles the rule allows show Allow and those it denies show Deny; the rest
#   show Not used; a name both allowed and denied (by hand) shows Deny
# - a name the rule carries that the store does not hold keeps its choice and is
#   marked "no such profile yet", so saving the card does not drop it silently
# - chosenAddresses reads the picker back as `addresses` and `addresses_deny`
# - the save sends both, and a card with only a profile chosen is NOT turned into
#   an acl-remove
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

my $page = PageScript::page_source("$root/starter/manager/files.md");
my $fns  = join "\n",
    map { PageScript::extract_function( $page, $_ ) }
    qw(escHtml addressRows addressBlock chosenAddresses savePerms);
my $dir = File::Temp->newdir;

my $js = <<'JS';
var ADDRESS_PROFILES = [ { name: 'office' }, { name: 'vpn' }, { name: 'blocked' } ];
function out(o) { console.log(JSON.stringify(o)); }

// The choice a row shows, read from the HTML the block made.
function shown(html, name) {
  var m = new RegExp('data-addr-profile="' + name + '"[^>]*>(.*?)</select>').exec(html);
  if (!m) return null;
  var s = /<option value="([a-z]*)" selected>/.exec(m[1]);
  return s ? s[1] : '';
}

var f = { addresses: ['office', 'ghost', 'both'], addresses_deny: ['blocked', 'both'] };
var block = addressBlock(f);
out({ step: 'block',
      heading: /Limited by address profile</.test(block),
      oldPickers: /Only these addresses|Never these|data-addr="(?:allow|deny)"/.test(block),
      rows: (block.match(/data-addr-profile=/g) || []).length,
      office: shown(block, 'office'), vpn: shown(block, 'vpn'), blocked: shown(block, 'blocked'),
      ghost: shown(block, 'ghost'), both: shown(block, 'both'),
      ghostMarked: /<label>ghost \(no such profile yet\)<\/label>/.test(block),
      choices: /<option value=""[^>]*>Not used<\/option><option value="allow"[^>]*>Allow<\/option><option value="deny"[^>]*>Deny<\/option>/.test(addressBlock({})),
      impact: (block.match(/data-impact="edit"/g) || []).length });
ADDRESS_PROFILES = [];
out({ step: 'none', text: addressBlock({}) });
ADDRESS_PROFILES = [ { name: 'office' }, { name: 'vpn' }, { name: 'blocked' } ];

function Sel(name, value) { this.name = name; this.value = value; }
Sel.prototype.getAttribute = function (a) { return a === 'data-addr-profile' ? this.name : null; };
function Card(sels) { this.sels = sels; }
Card.prototype.querySelectorAll = function (c) { return c === 'select[data-addr-profile]' ? this.sels : []; };

var c = new Card([ new Sel('office', 'allow'), new Sel('vpn', ''), new Sel('blocked', 'deny'), new Sel('ghost', 'allow') ]);
out({ step: 'chosen', chosen: chosenAddresses(c) });

// savePerms: a card with only an address profile must be an acl-set carrying it.
var sent = null;
var API = '/api';
function fetch(url, o) { sent = { url: url, body: JSON.parse(o.body) }; return new Promise(function () {}); }
function showStatus() {}
var rowNode = { getAttribute: function () { return 'internal/notes.md'; } };
function SaveCard(sels) { this.sels = sels; this.previousElementSibling = rowNode; }
SaveCard.prototype.closest = function () { return this; };
SaveCard.prototype.querySelector = function (c) { return c === '.mg-perm-owner' ? { value: '' } : null; };
SaveCard.prototype.querySelectorAll = function (c) { return c === 'select[data-addr-profile]' ? this.sels : []; };
var card = new SaveCard([ new Sel('office', 'deny') ]);
savePerms({ closest: function () { return card; } });
out({ step: 'save-address-only', action: /action=([a-z-]+)/.exec(sent.url)[1], body: sent.body });

var bare = new SaveCard([ new Sel('office', '') ]);
savePerms({ closest: function () { return bare; } });
out({ step: 'save-nothing', action: /action=([a-z-]+)/.exec(sent.url)[1] });
JS

open my $fh, '>', "$dir/t.js" or die "t.js: $!";
print {$fh} $fns, "\n", $js;
close $fh;
my @lines = split /\n/, `\Q$node\E \Q$dir/t.js\E 2>&1`;
require JSON::PP;
my %r = map { my $o = eval { JSON::PP::decode_json($_) }; $o ? ( $o->{step} => $o ) : () } @lines;
diag "node said: @lines" unless keys %r == 5;

subtest 'one picker of profiles, each Allow, Deny or not used' => sub {
    my $s = $r{block} or return fail('no result');
    ok $s->{heading}, 'headed "Limited by address profile"';
    ok !$s->{oldPickers}, 'and the two kind-filtered pickers are gone';
    is $s->{rows}, 5, 'a row for each profile in the store and each name the rule carries';
    is $s->{office},  'allow', 'a profile the rule allows shows Allow';
    is $s->{blocked}, 'deny',  'a profile the rule denies shows Deny';
    is $s->{vpn},     '',      'another profile is offered, Not used';
    is $s->{ghost},   'allow', 'a name the store does not hold keeps its choice';
    ok $s->{ghostMarked},      '...and is marked';
    is $s->{both},    'deny',  'a name both allowed and denied shows Deny (deny wins)';
    ok $s->{choices},          'each row offers Not used, Allow and Deny';
    is $s->{impact}, 5,        'every row declares its impact (lint 109)';
    like $r{none}{text}, qr/No address profiles yet/, 'an empty store says so';
};

subtest 'the picker is read back as addresses and addresses_deny' => sub {
    my $s = $r{chosen} or return fail('no result');
    is_deeply( $s->{chosen}, { addresses => [ 'office', 'ghost' ], addresses_deny => ['blocked'] },
        'Allow rows to addresses, Deny rows to addresses_deny, Not used to neither' );
};

subtest 'saving sends the address profiles, and a card with only a profile is not a removal' => sub {
    my $s = $r{'save-address-only'} or return fail('no result');
    is $s->{action}, 'acl-set', 'a card whose only content is an address profile is an acl-set';
    is_deeply( $s->{body}{addresses}, [], 'it sends addresses' );
    is_deeply( $s->{body}{addresses_deny}, ['office'], 'and addresses_deny' );
    my $n = $r{'save-nothing'} or return fail('no result');
    is $n->{action}, 'acl-remove', 'a card with nothing chosen anywhere still clears the rule';
};

done_testing;
