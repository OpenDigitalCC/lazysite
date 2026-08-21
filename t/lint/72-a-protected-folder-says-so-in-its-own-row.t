#!/usr/bin/perl
# A protected folder shows its protection in the folder's OWN expansion.
#
# Reported by the operator: it did not. The protection appeared only in the
# "Protected sections" card at the foot of the page, so answering "is THIS
# folder protected, and how?" meant scrolling to a different card and matching
# paths by eye.
#
# The card still exists and still lists everything - it answers a different
# question, "what is protected on this site". The gap was that a folder's own
# expansion, which is where an operator stands when they are thinking about
# that folder, said nothing.
#
# TWO THINGS THE BLOCK MUST GET RIGHT, and both are asserted, because a
# half-answer here is worse than none:
#
#   It must NOT imply "open" on an unprotected folder when a SITE-WIDE rule
#   covers it. That would be a confident wrong answer about whether visitors
#   can see something.
#
#   It must say what the policy MEANS - draft is hidden outright, gated
#   redirects to sign-in - because "draft" and "gated" are the two words an
#   operator is most likely to have the wrong way round.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $page = repo_root() . '/starter/manager/files.md';
plan skip_all => 'files page missing' unless -f $page;
my $src = do { open my $fh, '<', $page or die $!; local $/; <$fh> };

# STRUCTURAL, not a bare grep. `qr/protectionBlock\(f\)/` matches the
# function's own DEFINITION, so deleting the call site left it passing - the
# sabotage caught the test, not the code. Assert the call inside permsCard.
my ($perms) = $src =~ /function permsCard\(f\)\s*\{(.*?)\n\}/s;
ok( defined $perms, 'permsCard is present' ) or BAIL_OUT('cannot find permsCard');
like( $perms, qr/\+\s+protectionBlock\(f\)/,
    'the per-file expansion CALLS the protection block' )
    or diag( 'Without the call the only answer is in a card at the foot of '
        . 'the page, matched to this folder by eye.' );

like( $src, qr/PROTECTED_BY_PREFIX\[rows\[k\]\.prefix\]/,
    'sections are indexed by prefix for the rows to read' );

like( $src, qr/f\.type !== 'dir'/,
    'only folders are considered - a section gates a path, not a file' );

# The site-wide case. Saying nothing there would imply "not protected" on a
# site where everything is.
# Also structural: the site-wide message sits AFTER the early return, so a
# sabotage that returns unconditionally leaves the string in the source and
# unreachable. Grepping cannot tell present from reachable - assert the guard
# comes BEFORE the bare return within the function.
my ($block) = $src =~ /function protectionBlock\(f\)\s*\{(.*?)\n\}/s;
ok( defined $block, 'protectionBlock is present' )
    or BAIL_OUT('cannot find protectionBlock');
like( $block, qr/if \(!SITE_WIDE_RULE\) return '';/,
    'an unprotected folder returns early ONLY when no site-wide rule applies' )
    or diag( 'Returning unconditionally leaves the site-wide message in the '
        . 'source and unreachable - silence on a site-wide-gated site reads '
        . 'as "this folder is open", a confident wrong answer.' );
like( $block, qr/Covered by the site-wide rule/,
    'and says so when one does' );

# The two policies must be distinguishable by someone who has not memorised
# which is which.
like( $src, qr/hidden outright/,  'draft is explained, not just named' );
like( $src, qr/sent to sign in/,  'and so is gated' );

# The card at the foot is NOT removed - it answers a different question.
like( $src, qr/id="protected-card"/,
    'the site-wide Protected sections card is still there' )
    or diag( '"What is protected on this site" and "is this folder protected" '
        . 'are different questions; this change answers the second without '
        . 'removing the first.' );

# Re-render after the sections load, or the first paint has nothing to show.
like( $src, qr/paintFiles\(\);\s*\/\/ re-render/,
    'the listing repaints once the sections are known' )
    or diag( 'The sections fetch and the file listing race; without a repaint '
        . 'the folder rows show nothing until the operator navigates.' );

done_testing();
