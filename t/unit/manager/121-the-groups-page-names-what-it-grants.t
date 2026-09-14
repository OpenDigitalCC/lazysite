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
// manage_forms is granted directly AND inherited below, which is the case the
// row has to distinguish from a purely inherited one.
var caps = { manage_content: 1, manage_forms: 1 }, channelServices = {}, ge = 'ops';
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
// SM879 added inherited grants to the row. The page defines this map at the top
// of renderGroups; the stub has to mirror it or the extracted function throws
// before rendering anything. TWO capabilities here, so one row can be examined
// for the direct case and another for the inherited one.
var inherited = { manage_themes: ['cap-design'], manage_forms: ['cap-content'] };
$row
console.log(JSON.stringify({
    html:      row(['manage_content', 'Create and edit pages'], false),
    inherited: row(['manage_themes',  'Manage themes'],         false),
    both:      row(['manage_forms',   'Manage forms'],          false)
}));
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

# --- SM879: a capability that arrives from a bundle -------------------------
#
# Since SM631 a role holds nothing of its own, so before this the grid showed
# nine of the ten shipped roles as entirely unticked while they granted between
# three and eleven capabilities. RUN rather than grepped, for this file's own
# reason: the strings survive as fragments whether or not anything emits them.
like( $got->{inherited}, qr/checked disabled/,
    'an inherited capability is ticked and NOT editable' )
    or diag( 'A live checkbox here claims the group grants it and invites an '
        . 'unticking that writes a direct deny - which does not revoke the '
        . 'inherited grant, so the box springs back and the page looks broken.' );
like( $got->{inherited}, qr/cap-design/,
    'and names the bundle it comes from, so the operator knows where to go' );

# The BOTH case: a direct grant that is also inherited keeps its working
# control, because the direct half is real and revocable here.
unlike( $got->{both}, qr/disabled/,
    'a capability granted directly AND inherited keeps its editable checkbox' );
like( $got->{both}, qr/also inherited/,
    'and says so, because unticking will not take the access away' )
    or diag( 'Without this the operator unticks, sees the capability still in '
        . 'force, and has no way to learn why.' );

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

# --- SM866: the group NAME is visible, not only on hover --------------------
#
# THIS REVERSES SM665, which moved the group name out of brackets and into the
# row's `title` attribute. SM665's reason was "in a list of groups that is the
# same word twice on every row" - and that is not true of the seeded set:
# `cap-content` carries the label "Capability: content", `ch-files` carries its
# own, and the case where label and name ARE the same was already excluded by
# the existing `info.label !== g` guard, which renders the bare name alone.
#
# What SM665 kept was SM617's requirement that the technical name stay
# DISCOVERABLE. A title attribute does not meet it for the use the release
# manager actually has - "hard to locate groups when connecting with backend
# requests": a tooltip cannot be searched for with the browser's find, cannot be
# copied, and does not exist on a touch device. Discoverable by hover is not
# discoverable when you are cross-referencing a name you must type somewhere
# else.
#
# RUN, not grepped, for this file's own stated reason: the strings survive as
# concatenation fragments whether or not anything emits them.
my ($nm) = $src =~ /(var lbl\s*=\s*info\.label.*?\n\s*:\s*ge;)/s;
ok( $nm, 'the page carries the group-name builder' )
    or do { done_testing(); exit };

open my $njs, '>', "$dir/name.js" or die $!;
print {$njs} <<"JS";
function escHtml(x) { return String(x == null ? '' : x); }
function render(g, info) {
    var ge = escHtml(g);
    $nm
    return name;
}
console.log(JSON.stringify({
    labelled: render('cap-content', { label: 'Capability: content' }),
    // A group whose label IS its name: the guard must not print it twice.
    same:     render('members',     { label: 'members' }),
    // And one with no label at all.
    none:     render('sysops',      {})
}));
JS
close $njs;
my $n = eval { JSON::PP::decode_json(`\Q$node\E \Q$dir/name.js\E 2>&1`) };
ok( $n, 'the group-name builder ran' ) or do { done_testing(); exit };

like( $n->{labelled}, qr/Capability: content/,
    'the display name is shown, which is what an operator chooses by' );
like( $n->{labelled}, qr/\(cap-content\)/,
    'and the internal name is shown BESIDE it, not only in a tooltip - it is '
        . 'what the CLI, the audit trail and every backend request use' )
    or diag( 'SM665 put the name in a title attribute. A tooltip cannot be '
        . 'found with the browser\'s search, cannot be copied, and is absent '
        . 'on touch - so an operator matching a group to a backend request had '
        . 'to hover every row to find the one they meant.' );

# The guard SM665's reasoning was actually about, still holding.
my ($once) = ( $n->{same} =~ /members/ ? 1 : 0 );
ok( $once, 'a group whose label equals its name still renders' );
unlike( $n->{same}, qr/members.*\(members\)/s,
    'and is NOT printed twice - which is the case SM665 was right about' );
unlike( $n->{none}, qr/\(\s*\)/,
    'a group with no label shows no empty brackets' );
like( $n->{none}, qr/sysops/, 'just its name' );

done_testing();
