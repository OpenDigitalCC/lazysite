#!/usr/bin/perl
# SM352: the inventory of everything the engine inlines, and why it is a test.
#
# WHAT THIS IS INSTEAD OF. The filing proposed shipping
# Content-Security-Policy-Report-Only so the instance could measure what a real
# policy would break. That header is inert without a reporting endpoint - the
# browser evaluates the policy and reports nowhere - so the proposal really was
# "build a collector": an unauthenticated, cross-origin write endpoint, on a
# project whose gating story is that protected content is not in the served tree.
#
# It would have been building a data-collection surface to discover a fact the
# source already states. The engine inlined <script> and <style> in ten places
# - eight of them in the processor alone. They are listed below, and they were
# found by reading the file. No live traffic was required and none should be.
#
# SM352 STEPS 1-3, 2026-08-18: EIGHT have left - ten down to two. The fallback page chrome and the
# SM098 multi-step form rules are now /assets/lazysite-chrome.css, bundled into
# one file rather than split per feature - a rule that only matters on a page
# with a multi-step form costs nothing to carry, while a second request costs a
# round trip on every page that has one.
#
# The count going DOWN is the progress. The number in this test is the only
# place that fact is recorded mechanically, and it is why removing an entry has
# to be a deliberate edit rather than something a passing run absorbs.
#
# WHAT IT BUYS. Two things a collector would not have. It cannot be gamed by
# what happened to be visited, so the inventory is complete rather than
# representative. And it FAILS when an eleventh appears - which is the actual
# question, because CSP adoption is not blocked by these ten being unknown, it
# is blocked by the number never going down and nobody noticing when it goes up.
#
# THE CONCLUSION IT RECORDS. Under `script-src 'self'; style-src 'self'` every
# page of every site violates, several times, before a single layout or piece of
# content is considered. So no enforcing policy fits today, and the work CSP
# actually needs is moving these to files with the `?v=` busting the project
# already has, or threading a nonce through the render. That is a project, not a
# header, and this is the list it would start from.
#
# TWO AUDIENCES, AND THE PUBLIC SITE'S POLICY DOES NOT DEPEND ON THE MANAGER'S.
# This counted them together, which made the remaining work look larger than it
# is. They are different responses to different people:
#
#   the SITE      what a visitor receives. This is what a CSP is FOR. After
#                 step 4 it emits nothing inline TO A SITE WHOSE ASSET MIRROR
#                 HAS BEEN REWRITTEN - the theme tokens are a linked file. The
#                 generator stays in the source as the fallback for a mirror
#                 that predates the change, which is why the inventory below
#                 still carries the entry: the source emits it, the refreshed
#                 site does not receive it. Those are different questions and
#                 collapsing them is how an inventory starts lying.
#   the MANAGER   what an operator receives, signed in, on their own tooling.
#                 Its head script is 349 lines carrying four per-user values, a
#                 nav built from plugin conditionals, a theme prelude that must
#                 run before first paint, and a fetch wrapper that must replace
#                 window.fetch before anything captures a reference. Two of
#                 those are ORDERING constraints an external file cannot
#                 satisfy without a round trip in front of the render.
#
# So the manager can carry a looser policy - or the theme prelude a hash, since
# its content is static - without holding up the one that matters. Recorded
# because "ten inline blocks" invited exactly the wrong plan: emptying the
# manager to reach a site policy it has no bearing on.
#
# NOT COVERED, deliberately: layouts and page content. Those are the catalogue's
# and the author's, they are not in this tree, and SM362 is where that half
# lives. An inventory that claimed to cover them would be the more dangerous
# kind of wrong.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# The inventory. Each entry is matched against the file, so a block that moves
# still matches and a block that is deleted or renamed shows up as a change.
my @INLINE = (
    { name => 'theme custom properties',
        file => 'lazysite-processor.pl',
        kind => 'style',
        re   => qr/return "<style>\\n:root \{/,
        note => 'D013 - SM352 step 4 moved this to a mirrored file '
            . '(theme-tokens.css), so a site whose mirror has been written '
            . 'links it and receives NO inline style. The block survives as '
            . 'the fallback for a site whose mirror predates the change, and '
            . 'so is still emitted by this source - which is why the entry '
            . 'stays. The site-side count is 0 for a refreshed mirror and 1 '
            . 'for a stale one; a CSP can only be adopted once the operator '
            . 'knows which of those every site is.',
    },
    { name => 'manager UI head script',
        file => 'starter/lazysite/manager/layout.tt',
        kind => 'script',
        re   => qr/<script>/,
        note => 'the operator UI is a first-party application page',
    },
);

subtest 'every recorded inline block is still there' => sub {
    my %src;
    for my $e (@INLINE) {
        $src{ $e->{file} } //= do {
            open my $fh, '<', "$root/$e->{file}" or die "$e->{file}: $!";
            local $/;
            <$fh>;
        };
        like( $src{ $e->{file} }, $e->{re}, "$e->{kind}: $e->{name}" )
            or diag( "$e->{note}\n"
                . 'If this block was removed, remove it from the inventory too '
                . 'and note that CSP got one step closer.' );
    }
};

subtest 'and no unrecorded one has appeared' => sub {
    # Counted rather than matched, because the question is "did the number go
    # up", and a new block will not match any pattern here by definition.
    my %expected;
    $expected{ $_->{file} }++ for @INLINE;

    for my $file ( sort keys %expected ) {
        open my $fh, '<', "$root/$file" or die "$file: $!";
        my ( $n, @found ) = (0);
        while ( my $l = <$fh> ) {
            $n++;
            next if $l =~ /^\s*#/;                 # a comment is not an emission
            next if $l =~ m{s\{|s/|=~|message};    # matching content, not writing it
            next unless $l =~ /<(?:script|style)\b[^>]*>/i;
            push @found, $n;
        }
        close $fh;
        is( scalar @found, $expected{$file}, "$file inlines $expected{$file}" )
            or diag( "Found at lines: @found\n"
                . "Expected $expected{$file}. A new inline block is a new CSP "
                . "violation on every page it reaches. Add it to the inventory "
                . 'in this file with a note on whether it could have been a '
                . 'served asset instead.' );
    }
};

subtest 'and CSP is not claimed while they exist' => sub {
    # The honest end of it. Emitting a policy this engine violates on every page
    # would be the header saying something the response does not do - which is
    # the defect class this project keeps finding, dressed as a security control.
    my $src = do {
        open my $fh, '<', "$root/lazysite-processor.pl" or die $!;
        local $/;
        <$fh>;
    };
    unlike( $src, qr/^\s*print\s+"Content-Security-Policy:/m,
        'no enforcing CSP is emitted' )
        or diag( 'There are ' . scalar(@INLINE) . ' inline blocks in the '
            . 'inventory. An enforcing policy would break all of them.' );
};

done_testing();
