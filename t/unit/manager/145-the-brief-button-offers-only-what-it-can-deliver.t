#!/usr/bin/perl
# SM676: "i had brief option even though i didnt have briefs permission".
#
# Three facts, and only one of them was a defect.
#
#   * The button rendered UNCONDITIONALLY. Every other conditional control in
#     that action row is gated - migrateToLocal on the filename, toggleHistory
#     on GIT.enabled - and this one was gated on nothing.
#   * Reading a brief genuinely does NOT need manage_briefs: brief-read admits
#     manage_content OR manage_briefs, and anyone in the Files app holds the
#     former by definition. That is defensible and unchanged.
#   * Appending DOES need manage_briefs, and only that.
#
# So the panel read the brief, prompted for an entry, and refused the save - the
# refusal landing after the typing. That is the same shape as SM501's expired
# submission and SM655's tool that reported success: the surface let somebody
# complete work it was never going to accept.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $src  = do {
    open my $fh, '<', "$root/starter/manager/files.md" or die $!;
    local $/;
    <$fh>;
};
my $api = do {
    open my $fh, '<', "$root/lazysite-manager-api.pl" or die $!;
    local $/;
    <$fh>;
};

subtest 'the asymmetry this is about is real, and still there' => sub {
    # If these two ever gate the same way, the whole problem dissolves and this
    # file should be revisited rather than left asserting a distinction that no
    # longer exists.
    like( $api, qr/'brief-read'\s*=>\s*'manage_content\|manage_briefs'/,
        'reading admits either capability' );
    like( $api, qr/'brief-append'\s*=>\s*'manage_briefs'/,
        'appending admits only manage_briefs' )
        or diag( 'If append now accepts manage_content too, the button need '
            . 'not distinguish and this test is obsolete.' );
};

subtest 'the button is no longer unconditional' => sub {
    my ($fn) = $src =~ /function briefButton\(f\) \{(.*?)\n\}/s;
    ok( defined $fn, 'briefButton is present' ) or return;

    like( $fn, qr/BRIEFS\.read/, 'it consults what the caller may read' );
    like( $fn, qr/BRIEFS\.plugin/,
        'and whether the plugin that stores briefs is on' );
    like( $fn, qr/return ''/,
        'and renders nothing when there is nothing to offer' );
    like( $fn, qr/read-only/,
        'a caller who may only read is told so on the button' )
        or diag( 'Otherwise the label promises an edit it will refuse.' );
};

subtest 'no prompt for a write that will be refused' => sub {
    my ($fn) = $src =~ /function viewBrief\(btn\) \{(.*?)\n\}\n/s;
    ok( defined $fn, 'viewBrief is present' ) or return;

    # The check must come BEFORE the prompt. Asserting only that both strings
    # exist would pass with the guard placed after it, which is the bug.
    my $guard  = index( $fn, 'BRIEFS.append' );
    my $prompt = index( $fn, 'window.prompt' );
    cmp_ok( $guard, '>', -1, 'the append capability is checked' );
    cmp_ok( $prompt, '>', -1, 'and a prompt still exists for those who may' );
    cmp_ok( $guard, '<', $prompt,
        'the check comes BEFORE the prompt' )
        or diag( 'Checking after prompting is the defect: the refusal lands '
            . 'after the typing.' );

    like( $fn, qr/Authoring briefs/,
        'and the message names the capability that is missing' );
};

subtest 'the caller capabilities are fetched once, not per directory' => sub {
    like( $src, qr/function loadBriefCaps/, 'there is a loader' );
    like( $src, qr/loadPrincipals\(\)\.then\(loadGitStatus\)\.then\(loadBriefCaps\)/,
        'called once in the page init chain' );
    my ($loaddir) = $src =~ /function loadDir\((.*?)\n\}/s;
    unlike( $loaddir // '', qr/loadBriefCaps|action=whoami/,
        'and NOT on every directory load - it is a property of the session' );
};

done_testing();
