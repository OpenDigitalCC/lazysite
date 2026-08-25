#!/usr/bin/perl
# SM243 + SM244: warn at the moment of writing, and report what the site already
# knows about itself.
#
# The briefings say all of this. The problem the reporting agent named is that an
# agent reads them once and then works through a tool surface that cheerfully
# accepts the thing the briefing warned against - so the warning has to live where
# the mistake is made. write_file and create_page already surface _validate_page's
# warnings, so a check added there reaches the write path for free.
#
# Everything here is WARN, never refuse. A hand-written HTML page is occasionally
# the right answer; the complaint is silence, not permissiveness. SM228's refusal
# is different in kind - it catches a page that would be served as plain text,
# which is always broken.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $src  = do {
    open my $fh, '<', "$root/lazysite-mcp.pl" or die $!;
    local $/;
    <$fh>;
};

# The validator body, so an assertion about a check cannot pass on a mention
# somewhere else in the file.
#
# SM516 MC-10 split the seven checks out of _validate_page into named _check_*
# subs that sit immediately above it and are called from nowhere else, so the
# window is the FAMILY rather than the one sub. Still bounded, still not
# "anywhere in the file" - which is the property this extraction exists for.
my ($vp) = $src =~ /(sub _check_front_matter\b.*?sub _validate_page\b.*?)^sub /ms;
ok( defined $vp, '_validate_page body located' );

# --- SM243: the page-body guardrails ----------------------------------------
my %EXPECT = (
    'document-in-page'     => qr/<!DOCTYPE/,
    'style-block-in-page'  => qr/<style/,
    'api-page-is-a-document' => qr/api/,
    'chrome-in-page'       => qr/<nav/,
);
for my $kind ( sort keys %EXPECT ) {
    like( $vp, qr/kind\s*=>\s*'\Q$kind\E'/, "_validate_page warns '$kind'" );
}
like( $vp, $EXPECT{'document-in-page'},    'and really tests for a document body' );
like( $vp, $EXPECT{'chrome-in-page'},      'and really tests for page-baked chrome' );

# Each warning must name the ALTERNATIVE, not just the prohibition - the whole
# lesson of SM228's refusal message.
like( $vp, qr/STATIC FILE/,  'the document warning names the static-file route' );
like( $vp, qr/theme/,        'the style warning points at the theme' );
like( $vp, qr/unreachable/,  'the chrome warning names the real consequence' );

# They are warnings. If any of these became an issue/refusal, an ordinary write
# would start failing.
unlike( $vp, qr/push \@\$?issues,\s*\{\s*kind\s*=>\s*'(?:document-in-page|style-block-in-page|chrome-in-page)'/,
    'none of the SM243 checks is raised as a blocking issue' );

# --- SM243: the theme guardrails --------------------------------------------
{
    my $tsrc = do {
        open my $fh, '<', "$root/lib/Lazysite/Manager/Themes.pm" or die $!;
        local $/;
        <$fh>;
    };
    my ($ct) = $tsrc =~ /(sub action_create_theme\b.*?)^sub /ms;
    ok( defined $ct, 'action_create_theme body located' );
    # NB: the message escapes its apostrophe in the Perl source (layout\'s), so
    # match a phrase that does not cross it.
    like( $ct, qr/hides the layout/,
        'create_theme warns on a theme hiding layout chrome' );
    like( $ct, qr/opacity/,
        'and on content hidden by default' );
    like( $ct, qr/prefers-reduced-motion/,
        'naming the reduced-motion rule that is NOT a neutraliser - the specific '
            . 'thing that misled a careful reader' );
    like( $ct, qr/crawlers/,
        'and the consequence for no-JS visitors and crawlers' );
    # Warnings, not rejections: both patterns are legitimate with a fallback.
    unlike( $ct, qr/return \{ ok => 0[^}]*hides the layout/s,
        'a chrome-hiding theme is warned about, not refused' );
}

# --- SM244: audit_site reports the starter pages -----------------------------
{
    # SM516 MC-11 split the walk and the five passes out of _audit_site; the
    # family is contiguous and _audit_site is its last member.
    my ($as) = $src =~ /(sub _audit_collect\b.*?sub _audit_site\b.*?)^sub /ms;
    ok( defined $as, '_audit_site body located' );
    like( $as, qr/lazysite-starter/,
        'audit_site reads the provenance marker that nothing has ever read' );
    like( $as, qr/starter_pages/, 'and returns them as their own category' );
    like( $as, qr/starter_in_sitemap/,
        'plus the sitemap count - the ratio is what makes it obvious' );
    like( $as, qr/registered/,
        'each entry records where it is advertised' );
}

# --- SM243: a rename retires a URL, so it must offer the alias ---------------
# The standing rule is that every old URL gets an aliases: entry on its
# successor, and until now a person had to remember it - twenty legacy URLs were
# recovered by hand on one site after a conversion dropped them.
{
    my ($rp) = $src =~ /(sub _rename_page\b.*?)^sub /ms;
    ok( defined $rp, '_rename_page body located' );
    like( $rp, qr/alias_suggested/,
        'a rename always REPORTS the alias the old URL needs' );
    like( $rp, qr/add_alias/,
        'and writes it when asked' );
    # Reported by default, written on request: adding it edits the successor's
    # front matter, which would surprise anyone moving an unpublished page.
    like( $rp, qr/if \( \$a->\{add_alias\} \)/,
        'the WRITE is opt-in, not automatic' );
    # Idempotence and the no-front-matter case are asserted BEHAVIOURALLY in
    # t/unit/mcp/14-new-tool-behaviour.t, by renaming a page back and forth and
    # counting the entries. This file only checks the alias logic consults what
    # is already there - the previous assertion pinned the exact expression
    # (`index( $1, $alias ) < 0`) and broke on SM256 purely because the same
    # check moved into a named variable, which is the brittleness a source scan
    # buys you.
    like( $rp, qr/index\(\s*\$\w+,\s*\$alias\s*\)/,
        'the existing aliases are consulted before one is added' );
    like( $src, qr/add_alias\s*=> \{ type => 'boolean'/,
        'add_alias is a declared tool parameter' );
}

# --- SM243/SM224: an @group ACL entry never matches a remote partner ---------
{
    my $fsrc = do {
        open my $fh, '<', "$root/lib/Lazysite/Manager/Files.pm" or die $!;
        local $/;
        <$fh>;
    };
    my ($as) = $fsrc =~ /(sub action_acl_set\b.*?)^sub /ms;
    ok( defined $as, 'action_acl_set body located' );
    like( $as, qr/\@group entry matches/,
        'setting an @group ACL warns that it matches only a manager user' );
    like( $as, qr/token, MCP and WebDAV partners carry\s+.*no groups/s,
        'naming exactly which channels it does NOT apply to' );
    like( $as, qr/warnings/, 'and the warning is returned to the caller' );
    # It is advice, not a refusal - @group ACLs are correct for cookie users.
    unlike( $as, qr/return \{ ok => 0[^}]*\@group/s,
        'an @group ACL is still allowed' );
}

done_testing();
