#!/usr/bin/perl
# SM1344 (ruling 107): the Groups page limits a group by ADDRESS PROFILE with the
# Files card's one picker - a row per profile, each Not used, Allow or Deny - in
# place of SM1140's two rows of ticks ("Only from" / "Never from").
#
# Driven through the page's own JavaScript in node (PageScript), with a stand-in
# document:
#
# - groupAddressRows has one row per profile in the store, every choice on each
#   (a profile has no kind, SM1343); the group's allowed profiles show Allow, its
#   denied ones Deny, the rest Not used; a name both allowed and denied shows Deny;
#   a name the store does not hold keeps its choice and is marked
# - chosenGroupAddresses reads the picker back as addresses and addresses_deny
# - setGroupAddresses sends ONE request carrying both lists (key address_limit),
#   so a profile moved between Allow and Deny is never in neither list; a refusal
#   is shown and what the server holds is reloaded. The server's half of it (one
#   validated write, a half-update refused) is t/unit/users/60.
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

my $page = PageScript::page_source("$root/starter/manager/groups.md");
my $fns  = join "\n",
    map { PageScript::extract_function( $page, $_ ) }
    qw(escHtml groupAddressRows chosenGroupAddresses setGroupAddresses);
my $dir = File::Temp->newdir;

my $js = <<'JS';
var addressProfiles = [ { name: 'office' }, { name: 'vpn' }, { name: 'blocked' } ];
function out(o) { console.log(JSON.stringify(o)); }
function shown(html, name) {
  var m = new RegExp('data-addr-profile="' + name + '"[^>]*>(.*?)</select>').exec(html);
  if (!m) return null;
  var s = /<option value="([a-z]*)" selected>/.exec(m[1]);
  return s ? s[1] : '';
}

var html = groupAddressRows('g-ed', { addresses: ['office', 'ghost', 'both'], addresses_deny: ['blocked', 'both'] });
out({ step: 'rows',
      heading: /Limited by address profile/.test(html),
      oldRows: /Only from|Never from|type="checkbox"|data-addr-key=/.test(html),
      rows: (html.match(/data-addr-profile=/g) || []).length,
      office: shown(html, 'office'), vpn: shown(html, 'vpn'), blocked: shown(html, 'blocked'),
      ghost: shown(html, 'ghost'), both: shown(html, 'both'),
      ghostMarked: /ghost \(no such profile yet\)/.test(html),
      choices: /<option value=""[^>]*>Not used<\/option><option value="allow"[^>]*>Allow<\/option><option value="deny"[^>]*>Deny<\/option>/.test(html),
      onchange: (html.match(/onchange="setGroupAddresses\('g-ed'\)"/g) || []).length,
      impact: (html.match(/data-impact="edit"/g) || []).length });
addressProfiles = [];
out({ step: 'none', text: groupAddressRows('g-x', {}) });

function Sel(name, value) { this.name = name; this.value = value; }
Sel.prototype.getAttribute = function (a) { return a === 'data-addr-profile' ? this.name : null; };
var sels = [ new Sel('office', 'allow'), new Sel('vpn', ''), new Sel('blocked', 'deny'), new Sel('ghost', 'deny') ];
var document = {
  querySelector: function (q) {
    if (q !== '[data-addr-group="g-ed"]') return null;
    return { querySelectorAll: function (c) { return c === 'select[data-addr-profile]' ? sels : []; } };
  }
};
out({ step: 'chosen', chosen: chosenGroupAddresses('g-ed') });

var sent = [], answers = [], status = [], loads = 0;
function apiCall(b) { sent.push(b); return Promise.resolve(answers.shift() || { ok: 1 }); }
function showStatus(m, bad) { status.push([m, !!bad]); }
function loadGroups() { loads++; }
(async function () {
  setGroupAddresses('g-ed');
  await new Promise(function (r) { setTimeout(r, 10); });
  out({ step: 'save', sent: sent, status: status, loads: loads });
  sent = []; status = []; loads = 0;
  answers = [ { ok: 0, error: 'Only a sysop may limit a group by address' } ];
  setGroupAddresses('g-ed');
  await new Promise(function (r) { setTimeout(r, 10); });
  out({ step: 'refused', sent: sent, status: status, loads: loads });
})();
JS

open my $fh, '>', "$dir/t.js" or die "t.js: $!";
print {$fh} $fns, "\n", $js;
close $fh;
my @lines = split /\n/, `\Q$node\E \Q$dir/t.js\E 2>&1`;
require JSON::PP;
my %r = map { my $o = eval { JSON::PP::decode_json($_) }; $o ? ( $o->{step} => $o ) : () } @lines;
diag "node said: @lines" unless keys %r == 5;

subtest 'one picker of profiles, each Allow, Deny or not used' => sub {
    my $s = $r{rows} or return fail('no result');
    ok $s->{heading}, 'headed "Limited by address profile"';
    ok !$s->{oldRows}, 'and the two rows of ticks are gone';
    is $s->{rows}, 5, 'a row for each profile in the store and each name the group carries';
    is $s->{office},  'allow', 'a profile the group allows shows Allow';
    is $s->{blocked}, 'deny',  'one it denies shows Deny';
    is $s->{vpn},     '',      'another is offered, Not used';
    is $s->{ghost},   'allow', 'a name the store does not hold keeps its choice';
    ok $s->{ghostMarked},      '...and is marked';
    is $s->{both},    'deny',  'a name both allowed and denied shows Deny (deny wins)';
    ok $s->{choices},          'each row offers Not used, Allow and Deny';
    is $s->{onchange}, 5,      'each row saves the group on change';
    is $s->{impact},   5,      'and declares its impact (lint 109)';
    like $r{none}{text}, qr/No address profiles yet/, 'an empty store says so';
};

subtest 'the picker is read back as the two settings' => sub {
    is_deeply( ( $r{chosen} or return fail('no result') )->{chosen},
        { addresses => ['office'], addresses_deny => [ 'blocked', 'ghost' ] }, 'Allow and Deny rows, Not used in neither' );
};

subtest 'a change is one request carrying both lists' => sub {
    my $s = $r{save} or return fail('no result');
    is_deeply( $s->{sent}, [
            { action => 'group-settings-set', group => 'g-ed', key => 'address_limit',
                value => { addresses => ['office'], addresses_deny => [ 'blocked', 'ghost' ] } } ],
        'one group-settings-set with address_limit, both whole lists' );
    like $s->{status}[0][0], qr/\@g-ed counts only from office, never from blocked, ghost\./, 'and says what it set';
    is $s->{loads}, 1, 'and reloads';
    my $f = $r{refused} or return fail('no result');
    is scalar @{ $f->{sent} }, 1, 'a refusal is one request, not retried';
    ok $f->{status}[0][1] && $f->{status}[0][0] =~ /Only a sysop/, 'the refusal is shown as it came';
    is $f->{loads}, 1, 'and what the server holds is reloaded';
};

done_testing;
