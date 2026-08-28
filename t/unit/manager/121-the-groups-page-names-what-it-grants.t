#!/usr/bin/perl
# SM616/SM617: two things the Groups page did not say.
#
# SM616 - a group marked backend keeps whoever was already in it, deliberately:
# the flag is enforced at group-add ONLY, because a rule that retroactively
# revoked access would strip live grants on an upgrade. The page warned that
# "people are not added to it directly" and displayed that directly above the
# people who are in it, which reads as "these should not be here". The operator
# who asked concluded that retained members were invisible and that removing one
# meant re-enabling the flag, removing, then disabling again. None of that is so.
#
# SM617 - the grid shows human labels while every other surface names the same
# capability in code. whoami answers `manage_content`; the docs, the capability
# map and a partner's refusal all use it. The label had to be mapped back by
# inference.
#
# THE JAVASCRIPT IS RUN, following t/unit/users/29 and 35: both defects are in
# what the fragments EVALUATE to, and a source grep would pass on any string
# carrying the right words.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $page = repo_root() . '/starter/manager/groups.md';
plan skip_all => "no $page" unless -f $page;
chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
plan skip_all => 'node not installed' unless length $node && -x $node;

my $src = do { open my $fh, '<', $page or die $!; local $/; <$fh> };

# --- SM617: the capability row ---------------------------------------------
my ($row) = $src =~ /(var row = function\(c, isChannel\) \{.*?\n    \};)/s;
ok( $row, 'the page carries the capability row builder' );

my $dir = tempdir( CLEANUP => 1 );
open my $js, '>', "$dir/row.js" or die $!;
print {$js} <<"JS";
function escHtml(x) { return String(x == null ? '' : x); }
var caps = { manage_content: 1 }, channelServices = {}, ge = 'ops';
// SM427 added a per-capability sentence to the row. This test is about the
// TECHNICAL NAME on the label; an empty map renders the row without the
// sentence marker, which is the case it means to examine.
var CAP_GRANTS = {};
// SM675 added a second dormant marker to the row - a capability whose owning
// PLUGIN is off, beside SM180's channel-service one. The row builder reads
// `capabilityPlugin`, which the page defines at the top; this stub has to
// mirror the page's environment or the extracted function throws before it
// renders anything. Empty here: this test is about the technical name on the
// label, and no plugin state is the case it means to examine.
var capabilityPlugin = {};
$row
console.log(JSON.stringify({ html: row(['manage_content', 'Create and edit pages'], false) }));
JS
close $js;
my $got = eval {
    require JSON::PP;
    JSON::PP::decode_json(`\Q$node\E \Q$dir/row.js\E 2>&1`);
};
ok( $got, 'the row builder ran' ) or do { done_testing(); exit };

like( $got->{html}, qr/title="manage_content"/,
    'a capability row carries its TECHNICAL name, which is what every other '
        . 'surface calls it' );
like( $got->{html}, qr/Create and edit pages/,
    'and keeps the human label, which is what an operator chooses by' );

# --- SM616: the backend-group warning --------------------------------------
# RUN, not grepped. The first version of this asserted the sentences existed in
# the source, and a sabotage that removed the branch producing them still
# passed - the strings survive as concatenation fragments whether or not
# anything emits them. Extracting the block and executing it is the difference
# between "these words are in the file" and "a reader sees them".
my ($warn) = $src =~ /(if \(info\.assignable === false\) \{.*?\n    \})/s;
ok( $warn, 'the page carries the backend-group warning block' )
    or do { done_testing(); exit };

open my $wjs, '>', "$dir/warn.js" or die $!;
print {$wjs} <<"JS";
function escHtml(x) { return String(x == null ? '' : x); }
var allGroups = { 'nested-role': {} };     // a nested GROUP, not a person
function render(members) {
    var info = { assignable: false }, h = '';
$warn
    return h;
}
console.log(JSON.stringify({
    withPeople: render(['alice', 'bob', 'nested-role']),
    empty:      render(['nested-role'])
}));
JS
close $wjs;
my $w = eval { JSON::PP::decode_json(`\Q$node\E \Q$dir/warn.js\E 2>&1`) };
ok( $w, 'the warning block ran' ) or do { done_testing(); exit };

like( $w->{withPeople}, qr/2 people already here keep it/,
    'with members present it says how many keep the group - counting PEOPLE, '
        . 'not the nested groups that belong there' );
like( $w->{withPeople}, qr/never.*takes access away/s,
    'and that marking a group backend takes nothing away' );
like( $w->{withPeople}, qr/do not need to.{0,40}change this setting/s,
    'and that removing one needs no change to the setting' );
unlike( $w->{empty}, qr/already here keep it/,
    'and says none of that when there is nobody to say it about' );
like( $w->{empty}, qr/not added to it from now on/,
    'while still naming the rule for what happens next' );

done_testing();
