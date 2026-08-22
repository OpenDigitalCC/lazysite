#!/usr/bin/perl
# SM455: setting an AI up is one flow on one page, and the grant is still a
# decision the operator makes with their eyes open.
#
# WHAT THE OPERATOR MET. The connector card appeared only once the account
# already held `api` or `mcp`. That capability comes from GROUP MEMBERSHIP, set
# on another page - so the sequence was: go to Groups, add the account, come
# back, find this page showing what it loaded BEFORE the change, reload, and
# only then pick a client. Doing something correct and seeing no effect is
# indistinguishable from the thing having failed, which is the SM445 shape.
#
# THE REMEDY IS ASSEMBLY, NOT INVENTION. SM100's picker is careful work and is
# not replaced. It is simply shown earlier, and told to grant the group the
# chosen client needs - because the client DETERMINES the channel: a web or
# desktop assistant speaks MCP, a script speaks the API.
#
# THE SCOPE NOTE IS THE PART THIS TEST GUARDS. A group grant is a PERMISSION
# decision and must stay visible and auditable; packaging it must not turn
# "give this agent write access to the site" into an implied side effect of
# picking from a list. So the flow must NAME the group, say what it grants,
# ask first, and go through the same action the Groups page uses.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $page = repo_root() . '/starter/manager/users.md';
plan skip_all => 'users page missing' unless -f $page;
my $src = do { open my $fh, '<', $page or die $!; local $/; <$fh> };

subtest 'the picker no longer waits for the capability' => sub {
    # THE CONDITION ITSELF, not the body under it. An earlier version of this
    # assertion looked for the old body text after the gate, so restoring the
    # gate passed - the sabotage moved the body and the regex simply stopped
    # matching, which reads identically to the gate being absent.
    my ($gate) = $src =~ /\n\s*if \(([^)]*)\) \{\n\s*var needHint/;
    ok( defined $gate, 'the connect panel has a findable condition' );
    unlike( $gate, qr/\bmcp\b|\bapi\b/,
        'and it is not gated on already holding a channel' )
        or diag( "the condition was: $gate\n"
            . 'Gating it there is what made this a two-page job: the panel '
            . 'appeared only after a change made on another page.' );
    like( $src, qr/This account has no remote channel yet/,
        'and an account without one is told what will happen' );
};

subtest 'the client chooses the channel, and the channel chooses the group' => sub {
    like( $src, qr/CLIENT_CHANNEL\s*=\s*\{[^}]*web:\s*'mcp'/,
        'a web assistant needs mcp' );
    like( $src, qr/CLIENT_CHANNEL\s*=\s*\{[^}]*code:\s*'api'/,
        'a script needs api' );
    like( $src, qr/CLIENT_GROUP\s*=\s*\{[^}]*code:\s*'agent-ai'/,
        'and the group that grants it is named, not guessed' );
};

subtest 'THE GRANT IS NAMED, ASKED ABOUT, AND AUDITED THE SAME WAY' => sub {
    my ($fn) = $src =~ /function connectAs\(user, client\) \{(.*?)\nfunction /s;
    ok( defined $fn, 'connectAs is present' ) or return;

    # JOIN THE CONCATENATION BEFORE MATCHING. The confirmation is built from
    # several quoted fragments across several lines, so asserting on the
    # sentence as a reader sees it means undoing the concatenation first -
    # otherwise the test is really asserting where the line breaks fall, and
    # would fail the next time somebody reflows the file.
    ( my $flat = $fn ) =~ s/'\s*\+\s*\n?\s*'//g;
    $flat =~ s/\s*\+\s*\n\s*/ + /g;
    $flat =~ s/\s+/ /g;

    like( $fn, qr/mgConfirm\(/, 'it asks before granting' )
        or diag( 'A permission change that happens because you picked a client '
            . 'from a list is a side effect, not a decision.' );
    like( $fn, qr/Add "' \+ user \+ '" to the group/,
        'the confirmation names the account and the group' );
    like( $flat, qr/That grants the .{0,20}need.{0,20}channel/,
        'and says what the group grants' );
    like( $flat, qr/same change as ticking the group on the Groups page/,
        'and that it is the same change made elsewhere' );
    like( $fn, qr/action: 'group-add'/,
        'it goes through the SAME action the Groups page uses' )
        or diag( 'A private path would produce a different audit entry for the '
            . 'same decision, and the trail would then depend on which page '
            . 'the operator happened to use.' );
};

subtest 'a missing role group is reported, not substituted' => sub {
    my ($fn) = $src =~ /function connectAs\(user, client\) \{(.*?)\nfunction /s;
    like( $fn, qr/allGroups\.hasOwnProperty\(group\)/,
        'the group is checked for existence' );
    like( $fn, qr/does not exist on this site/,
        'and its absence is explained rather than worked around' )
        or diag( 'Silently granting some other group that happens to carry the '
            . 'capability would be choosing a permission on the operator\'s '
            . 'behalf.' );
};

subtest 'the page stops disagreeing with itself' => sub {
    my ($fn) = $src =~ /function connectAs\(user, client\) \{(.*?)\nfunction /s;
    like( $fn, qr/rowsByUser\[user\]\.settings\[need\] = true/,
        'the local view is updated after the grant' )
        or diag( 'Leaving it stale is the original complaint: a page that '
            . 'silently disagrees with what you just did.' );
    like( $fn, qr/allGroups\[group\]/, 'including group membership' );
};

done_testing();
