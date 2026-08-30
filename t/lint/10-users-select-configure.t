#!/usr/bin/perl
# SM144: on the Users page, SELECTING an account and CONFIGURING it must stay
# two distinct surfaces - field feedback was that operators could not tell
# whether they were editing a top-level or a sub-user account, and that nesting
# shrank the editor. The fix is structural: the tree carries only summaries +
# an identity banner + a Configure button (NO inline settings), and editing
# happens in a single full-width editor sheet with a coloured header naming the
# account - identical size at any tree depth. This gate pins the load-bearing
# markers so a refactor that puts settings back inline (re-introducing the
# shrinking-and-ambiguous panels) fails the build.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $page = repo_root() . '/starter/manager/users.md';
open my $fh, '<', $page or BAIL_OUT("cannot read $page: $!");
my $src = do { local $/; <$fh> };
close $fh;

# Selecting: ONE line per account (name + role + lineage), with the Configure
# button on the row itself - no expand-to-reveal step - and sub-users nested.
like( $src, qr/mg-acc-line/, 'accounts render as a single line' );
like( $src, qr/mg-acc-kids/, 'sub-users nest as an indented tree' );
like( $src, qr/mg-acc-leaf/, 'a leaf account is a plain one-line row (no disclosure)' );
like( $src, qr/sub-user of /, 'lineage names a sub-user\'s parent' );
like( $src, qr/mg-configbtn[^>]*data-cfg=/, 'Configure button carries the account it opens' );
like( $src, qr/event\.stopPropagation\(\);configureUser\(/,
    'Configure opens the sheet without toggling the subtree' );

# The tree row must NOT build the settings inline - those ids belong only in the
# sheet (accountSettingsHtml).
my ($rowfn) = $src =~ /function renderUserRow\(.*?\n\}/s;
ok( defined $rowfn, 'renderUserRow is present' );
unlike( $rowfn // '', qr/id="note-|id="scope-|sec\('Account'/,
    'the tree row renders NO settings fields (they live in the sheet only)' );

# Configuring: a single full-width sheet with a coloured header, filled on demand.
like( $src, qr/id="cfg-sheet"/, 'the editor sheet element exists' );
like( $src, qr/class="mg-sheet-head"/, 'the sheet has a header bar' );
like( $src, qr/function accountSettingsHtml\(/, 'settings are built by a dedicated function' );
like( $src, qr/function renderConfigSheet\(/, 'the sheet is filled by renderConfigSheet' );
like( $src, qr/Configuring ' \+ escHtml\(user\)/, 'the sheet header names the account being configured' );
like( $src, qr/function closeConfig\(/, 'the sheet can be closed' );

# Hierarchy reads from the nesting indent (no row tint - removed as a distraction).
like( $src, qr/mg-acc-kids/, 'sub-users nest under an indented tree container' );

# The CSS backs it: a fixed, accent-headed sheet (not a nested shrinking panel).
my $css = repo_root() . '/starter/lazysite/manager/assets/manager-classic.css';
open my $cf, '<', $css or BAIL_OUT("cannot read $css: $!");
my $csrc = do { local $/; <$cf> };
close $cf;
like( $csrc, qr/\.mg-sheet\s*\{[^}]*position:\s*fixed/s, 'the sheet is a fixed overlay (consistent position)' );
like( $csrc, qr/\.mg-sheet-panel\s*\{[^}]*width:\s*min\(/s, 'the sheet has a fixed width (consistent at any depth)' );
# SM-DS1: the head is no longer an accent bar - the design moved the manager to
# same-surface headers. The PROPERTY this was protecting survives: the sheet's
# head must be visually separated from its body, so a sheet reads as one object
# at any nesting depth. Separation by a rule is as good as separation by fill,
# and pinning the fill refused a legitimate design change while proving nothing
# the border does not.
like( $csrc, qr/\.mg-sheet-head\s*\{[^}]*(border-bottom|background):/s,
    'the head is separated from the body it sits above' );
like( $csrc, qr/\.mg-sheet-head\s*\{[^}]*position:\s*sticky/s,
    'and stays visible while the sheet scrolls' );
like( $csrc, qr/\.mg-acc-kids\s*\{[^}]*border-left/s, 'nested sub-trees are indented with a rule' );

# Create-user group staging (field report 2026-07-13): a group picked in the
# input but not committed with Enter / the picker's Add was silently dropped
# when "Add user" was clicked - the account was created with no groups. The
# create flow must flush the pending input (and refuse an unresolvable name)
# BEFORE it snapshots the staged list.
{
    my ($adduser) = $src =~ /function addUser\(\)\s*\{(.*?)\n\}/s;
    ok( defined $adduser, 'addUser() body found' );
    like( $adduser, qr/new-group-input/,
        'addUser() reads the pending group input (flush-before-create)' );
    like( $adduser, qr/allGroups\[pending\]/,
        'an unresolvable pending group name blocks the create (no silent drop)' );
    ok( $adduser =~ /new-group-input.*newUserGroups\.slice\(\)/s,
        'the pending input is flushed BEFORE the staged list is snapshotted' );
}

done_testing();
