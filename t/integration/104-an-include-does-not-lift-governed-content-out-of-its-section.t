#!/usr/bin/perl
# SM898: `::: include` does not lift governed content into a page outside the
# section that governs it.
#
# THE FIELD FINDING, 0.14.3 test plan W5b, measured on the test site as an
# anonymous visitor with no cookie. A draft section held /zz-w5p/partial.html;
# anonymous GET of the partial and of the section's own page both answered 404,
# as designed. A page OUTSIDE the section, /zz-w5-outside2.md, containing one
# line - `::: include /zz-w5p/partial.html` - answered 200 with the partial's
# text in the body. The same for a read-restricted section. So an include read
# a file the requester may not read and printed it into a page the requester
# may read. Who can exploit it: anyone who can write a page outside the
# section, which on a multi-author site is exactly the sub-user whose grant
# stops at their own folder.
#
# WHY NOTHING CAUGHT IT. t/integration/103 - SM888 A3, which widened the
# include's confinement to reach the private store - put its "the include
# still refuses what it always refused" assertion FIRST, as the discipline
# requires. But what it always refused was the lazysite/ management tree, and
# that is the only thing the assertion tested. Nothing had ever asserted that
# a governed section's content stays inside its section, because before A3
# the store was simply out of reach and the question never came up. A3 made
# it reachable and the assertion that should have guarded it did not exist.
#
# THE RULE, and why it needs no identity: governed content is includable only
# by a page under the SAME governing entry. A page in the section is gated by
# that entry already, so it may include the section's partials (A3's case,
# kept). A page anywhere else may not - whoever is asking. Identity-free means
# the refusal renders the same for everyone, so a cached public page cannot
# carry one reader's view to another; the engine already refuses to cache
# governed pages, and this rule never makes an ungoverned page's render depend
# on who asked.
#
# Written BEFORE the fix, and it failed - the two "outside" subtests - on the
# code that shipped in 0.14.3. That is the reproduction.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_test_site run_processor site_tempdir);

my $docroot = site_tempdir();
my $priv    = "$docroot-lazysite-private";
setup_test_site($docroot);
make_path( "$docroot/lazysite/auth", "$priv/drafts", "$priv/board", "$priv/library/shelf" );

# Four governed entries: a DRAFT section, a READ-RESTRICTED section, and -
# as in t/integration/103 - `library`, governed with no read list so anonymous
# may see it, with a TIGHTER read-listed rule nested inside it.
open my $af, '>', "$docroot/lazysite/auth/acls.json" or die $!;
print {$af} '{'
    . '"drafts":{"draft":1,"owner":"alice"},'
    . '"board":{"read":["alice"],"owner":"alice"},'
    . '"library":{"owner":"alice"},'
    . '"library/shelf":{"read":["bob"],"owner":"alice"}'
    . '}';
close $af;

sub write_file {
    my ( $path, $text ) = @_;
    ( my $dir = $path ) =~ s{/[^/]+\z}{};
    make_path($dir) unless -d $dir;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $text;
    close $fh;
    return;
}

my $DRAFT_TEXT = 'DRAFT-PARTIAL-SM898-MUST-NOT-LEAK';
my $BOARD_TEXT = 'BOARD-PARTIAL-SM898-MUST-NOT-LEAK';
my $SHELF_TEXT = 'SHELF-PARTIAL-SM898-MUST-NOT-LEAK';

write_file( "$priv/drafts/partial.html",        "<p>$DRAFT_TEXT</p>\n" );
write_file( "$priv/board/partial.html",         "<p>$BOARD_TEXT</p>\n" );
write_file( "$priv/library/shelf/partial.html", "<p>$SHELF_TEXT</p>\n" );
write_file( "$priv/library/_aside.md",          "ASIDE FROM THE LIBRARY\n" );

# The section's OWN page including its own partial - the case A3 fixed.
write_file( "$priv/library/page.md",
    "---\ntitle: Lib\n---\n\n::: include\n./_aside.md\n:::\n" );

# Public pages OUTSIDE every section, each including governed content.
write_file( "$docroot/outside-draft.md",
    "---\ntitle: O1\n---\n\nBEFORE\n\n::: include\n/drafts/partial.html\n:::\n\nAFTER\n" );
write_file( "$docroot/outside-board.md",
    "---\ntitle: O2\n---\n\nBEFORE\n\n::: include\n/board/partial.html\n:::\n\nAFTER\n" );
# A page in the readable section including the TIGHTER nested rule's partial:
# a different governing entry, so refused too.
write_file( "$priv/library/wants-shelf.md",
    "---\ntitle: W\n---\n\nLIBRARY PAGE\n\n::: include\n/library/shelf/partial.html\n:::\n" );

sub body_of {
    my ($out) = @_;
    $out //= '';
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return $out;
}

sub get {
    my ( $url, %env ) = @_;
    # SCALAR context, deliberately: run_processor ends in qx(), and called in
    # list context it returns one element per line, so body_of would see
    # "Status: 200 OK" and nothing else. The first draft of this file did
    # exactly that, and every assertion about the body passed or failed on a
    # single header line.
    my $out = run_processor( $docroot, $url, %env );
    return body_of($out);
}

# --- the leak, anonymous ------------------------------------------------------

subtest 'a public page cannot include a DRAFT section partial' => sub {
    my $body = get('/outside-draft');
    like( $body, qr/BEFORE/, 'the public page itself renders' );
    unlike( $body, qr/\Q$DRAFT_TEXT\E/, 'the draft partial is NOT in it' )
        or diag( 'W5b: a draft section answers 404 to the public so that '
            . 'nothing confirms the content exists - and one include line '
            . 'undid that.' );
    like( $body, qr/include-error/, 'the include is refused, visibly' );
};

subtest 'a public page cannot include a READ-RESTRICTED section partial' => sub {
    my $body = get('/outside-board');
    like( $body, qr/BEFORE/, 'the public page itself renders' );
    unlike( $body, qr/\Q$BOARD_TEXT\E/, 'the restricted partial is NOT in it' );
    like( $body, qr/include-error/, 'the include is refused, visibly' );
};

# --- the rule is "same governing entry", not "any governed page" -------------
#
# Driven WITHOUT signing in, deliberately. The rule compares governing entries
# and never asks who is reading, so a governed-but-readable section (library:
# an owner, no read list - anonymous may see it) is enough to show both halves:
# its own page includes its own partial, and its own page may NOT include a
# partial from a tighter rule nested inside it. A read-listed section's page
# would need a session the harness does not mint through headers; the first
# draft tried, got a 302, and its "not in the body" assertion passed on an
# empty redirect body - the vacuous pass this file exists to avoid.

subtest 'a governed page cannot include a TIGHTER sub-section partial' => sub {
    my $body = get('/library/wants-shelf');
    like( $body, qr/LIBRARY PAGE/, 'the library page renders to the public' )
        or diag("got:\n$body");
    unlike( $body, qr/\Q$SHELF_TEXT\E/, 'the nested restricted partial is NOT in it' )
        or diag( 'A tighter rule inside a section is a different audience. '
            . 'Allowing "any governed page" would hand it to the outer one.' );
    like( $body, qr/include-error/, 'the include is refused, visibly' );
};

# --- what must keep working (A3) ---------------------------------------------

subtest 'a governed page still includes ITS OWN partial' => sub {
    my $body = get('/library/page');
    like( $body, qr/ASIDE FROM THE LIBRARY/, 'K5 stays fixed: the section page carries its partial' )
        or diag("got:\n$body");
    unlike( $body, qr/include-error/, 'and no include error is rendered' );
};

done_testing();
