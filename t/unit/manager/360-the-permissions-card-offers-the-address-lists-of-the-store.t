#!/usr/bin/perl
# SM1139 (slice B of SM1134): the Files page's permissions card lets a rule name
# address lists, chosen from the store, and sends exactly the names picked.
#
# Driven through the page's own JavaScript in node (PageScript), with a stand-in
# card:
#
# - an allow list is offered under "Only these addresses" and a deny list under
#   "Never these", never the other way round
# - the lists the rule already names are selected
# - a name the rule carries that the store does not hold stays selected and says
#   "no such list yet", so saving the card does not drop it silently
# - chosenAddresses reads back the selected names of each picker
# - the save sends `addresses` and `addresses_deny`, and a card with an address
#   list and nothing else is NOT turned into an acl-remove
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
    qw(escHtml addressOptions addressBlock chosenAddresses savePerms);
my $dir = File::Temp->newdir;

my $js = <<'JS';
var ADDRESS_LISTS = [ { name: 'office', kind: 'allow' }, { name: 'vpn', kind: 'allow' },
                      { name: 'blocked', kind: 'deny' } ];
function out(o) { console.log(JSON.stringify(o)); }

function Opt(v, sel) { this.value = v; this.selected = sel; }
function Sel(opts) { this.options = opts; }
function Card(allowSel, denySel) {
  this.sels = { 'select[data-addr="allow"]': new Sel(allowSel), 'select[data-addr="deny"]': new Sel(denySel) };
}
Card.prototype.querySelector = function (c) { return this.sels[c] || null; };

var f = { addresses: ['office', 'ghost'], addresses_deny: ['blocked'] };
var block = addressBlock(f);
out({ step: 'block',
      allowHasOffice: /<option value="office" selected>/.test(block),
      allowHasVpn: /<option value="vpn">/.test(block),
      allowOffersDeny: /data-addr="allow"[^]*?<option value="blocked">[^]*?data-addr="deny"/.test(block),
      ghost: /<option value="ghost" selected>ghost \(no such list yet\)<\/option>/.test(block),
      denySelected: /<option value="blocked" selected>/.test(block),
      impact: (block.match(/data-impact="edit"/g) || []).length });

var c = new Card([ new Opt('office', true), new Opt('vpn', false), new Opt('ghost', true) ],
                 [ new Opt('blocked', false) ]);
out({ step: 'chosen', chosen: chosenAddresses(c) });

// savePerms: a card with only an address list must be an acl-set carrying it.
var sent = null;
var API = '/api';
function fetch(url, o) { sent = { url: url, body: JSON.parse(o.body) }; return new Promise(function () {}); }
function showStatus() {}
var rowNode = { getAttribute: function () { return 'internal/notes.md'; } };
function SaveCard(sels) {
  this.sels = sels; this.previousElementSibling = rowNode;
}
SaveCard.prototype.closest = function () { return this; };
SaveCard.prototype.querySelector = function (c) {
  if (c === '.mg-perm-owner') return { value: '' };
  return this.sels[c] || null;
};
SaveCard.prototype.querySelectorAll = function () { return []; };
var card = new SaveCard({ 'select[data-addr="allow"]': new Sel([ new Opt('office', true) ]),
                          'select[data-addr="deny"]': new Sel([]) });
savePerms({ closest: function () { return card; } });
out({ step: 'save-address-only', action: /action=([a-z-]+)/.exec(sent.url)[1], body: sent.body });

var bare = new SaveCard({ 'select[data-addr="allow"]': new Sel([ new Opt('office', false) ]),
                          'select[data-addr="deny"]': new Sel([]) });
savePerms({ closest: function () { return bare; } });
out({ step: 'save-nothing', action: /action=([a-z-]+)/.exec(sent.url)[1] });
JS

open my $fh, '>', "$dir/t.js" or die "t.js: $!";
print {$fh} $fns, "\n", $js;
close $fh;
my @lines = split /\n/, `\Q$node\E \Q$dir/t.js\E 2>&1`;
require JSON::PP;
my %r = map { my $o = eval { JSON::PP::decode_json($_) }; $o ? ( $o->{step} => $o ) : () } @lines;
diag "node said: @lines" unless keys %r == 4;

subtest 'the card offers lists of the right kind and keeps what the rule names' => sub {
    my $s = $r{block} or return fail('no result');
    ok $s->{allowHasOffice}, 'the allow list the rule names is selected under "Only these addresses"';
    ok $s->{allowHasVpn},    'another allow list is offered, unselected';
    ok !$s->{allowOffersDeny}, 'a deny list is not offered under "Only these addresses"';
    ok $s->{denySelected},   'the deny list the rule names is selected under "Never these"';
    ok $s->{ghost},          'a name the store does not hold stays selected and is marked';
    is $s->{impact}, 2,      'both pickers declare their impact (lint 109)';
};

subtest 'the names picked are read back' => sub {
    my $s = $r{chosen} or return fail('no result');
    is_deeply( $s->{chosen}, { addresses => [ 'office', 'ghost' ], addresses_deny => [] },
        'only the selected options of each picker' );
};

subtest 'saving sends the address lists, and a card with only a list is not a removal' => sub {
    my $s = $r{'save-address-only'} or return fail('no result');
    is $s->{action}, 'acl-set', 'a card whose only content is an address list is an acl-set';
    is_deeply( $s->{body}{addresses}, ['office'], 'it sends addresses' );
    is_deeply( $s->{body}{addresses_deny}, [], 'and addresses_deny' );
    my $n = $r{'save-nothing'} or return fail('no result');
    is $n->{action}, 'acl-remove', 'a card with nothing chosen anywhere still clears the rule';
};

done_testing;
