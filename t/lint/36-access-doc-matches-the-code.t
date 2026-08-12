#!/usr/bin/perl
# SM290: the access-control reference is asserted against the code.
#
# This document has twice stated the opposite of the behaviour and been believed
# both times - once for three releases (a per-file ACL "has no effect on an
# anonymous read", flagged as the single most important cell, after SM223 had
# made it false), and once for about a year (no partner can match an @group,
# which was false for WebDAV). Neither was a coding error. Both were prose that
# drifted from the code while every reader trusted it.
#
# PROSE ABOUT CODE IS UNVERIFIED CODE. The only difference from a broken
# function is that nothing fails when it is wrong. So the factual tables get a
# test, in the manner of t/lint/31 (the processor's ACL copy matches the shared
# one) and t/lint/32 (the manager guide covers the nav).
#
# WHAT IS DELIBERATELY NOT PINNED: the reasoning, the trade-offs, the appendix,
# and every judgement in the document. An editor must be able to improve those
# without fighting a test, and a lint that guards prose style would be worse
# than none. Only claims that can be checked against source are checked.
#
# And a lint that only asserts a HEADING exists is worse than no lint: it
# reports green while the prose beneath it lies. Every assertion below checks
# content.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or die "$p: $!";
    my $t = do { local $/; <$fh> };
    close $fh;
    return $t;
}

my $DOC  = slurp("$root/docs/architecture/access-control-model.md");
my $FEAT = slurp("$root/docs/FEATURES.md");
my $ACL  = slurp("$root/lib/Lazysite/Auth/Acl.pm");
my $PROC = slurp("$root/lazysite-processor.pl");

# The reference half only - the appendix is history and may say what was true
# when it was written.
my ($REF) = $DOC =~ /\A(.*?)^# Appendix/ms;
ok( $REF, 'the reference and the appendix are separable' );
$REF //= $DOC;

# --- the scope grammar matches what the resolver actually resolves ----------
subtest 'scope grammar' => sub {
    like( $REF, qr/\bexact key\b|One file/i, 'the reference lists an exact-file scope' );

    # The landing-page rule: a folder key governs `<folder>.md`.
    like( $REF, qr/landing page/i, 'documents the section landing page' );
    like( $ACL, qr/\\\.\(\?:md\|url\|html\)/,
        'and the resolver has the landing-page branch' );

    # The site-wide scope, and that it is the WEAKEST. Both halves matter: a
    # root rule that beat a longer prefix would make a public carve-out
    # impossible, which is most of what makes the scope usable.
    like( $REF, qr/whole site/i, 'documents the site-wide scope' );
    like( $REF, qr/weakest/i,    'and says it is the weakest rule' );
    like( $ACL, qr{for my \$rk \( '/', '', '\.' \)},
        'the resolver accepts the documented root spellings' );

    # Documented-but-unreachable is the exact defect SM287 was: a scope named
    # here must be reachable in the code.
    my ($entry) = $ACL =~ /(sub _acl_entry_for\b.*?\n\})/s;
    ok( $entry, 'found the resolver' );
    like( $entry, qr{index\( \$rel, "\$p/" \)},
        'folder prefixes are matched by prefix, as documented' );
    my $root_at   = index( $entry, "for my \$rk" );
    my $prefix_at = index( $entry, 'best_len' );
    cmp_ok( $root_at, '>', $prefix_at,
        'and the root check comes AFTER the prefix loop - the documented '
            . 'ordering, not merely the documented existence' );
};

# --- the subject grammar ----------------------------------------------------
subtest 'subject grammar' => sub {
    like( $REF, qr/protection is opt-in/i,
        'documents that no entry means allowed' );
    like( $ACL, qr/return 1 unless \$a;/,
        'and the code treats "no entry" as allowed' );

    like( $REF, qr/owner/i,         'documents the owner' );
    like( $ACL, qr/\$a->\{owner\}/, 'and the code allows the owner' );

    like( $REF, qr/nested groups expand|nested groups\*\* expand/i,
        'documents that nested groups expand' );
    like( $ACL, qr/group_closure/,
        'and the code expands them through the closure' );

    # The operator-bypass asymmetry. Stated in the doc because getting it wrong
    # in either direction is a defect: consulting _is_operator anonymously would
    # make the whole feature inert on an unsecured site.
    like( $REF, qr/never on the anonymous read path/i,
        'documents that the operator bypass does not apply to public reads' );
    unlike( $PROC, qr/^[^#]*_acl_denied/m,
        'and the processor never routes the public path through _acl_denied' );
};

# --- the two policies -------------------------------------------------------
subtest 'the policies, including the empty-list asymmetry' => sub {
    like( $REF, qr/\bgated\b/i, 'documents the gated policy' );
    like( $REF, qr/\bdraft\b/i, 'documents the draft policy' );
    like( $REF, qr/404/,        'and that draft answers 404' );

    # The asymmetry is the load-bearing part and lived only in a code comment.
    like( $REF, qr/empty read list|Empty read list/,
        'documents what an empty read list means' );
    like( $PROC, qr/sub _acl_is_draft/, 'the draft predicate exists' );
    like( $PROC, qr/never allowed into a draft section/i,
        'and the code refuses an anonymous request to a draft with no list' );
};

# --- whose groups apply, by channel -----------------------------------------
# THE table that produced SM288. Checked against the actual assignment in each
# CGI, which is what nobody was doing when the document claimed all three
# behaved alike.
subtest 'the per-channel group table matches the channels' => sub {
    my %CHANNEL = (
        'lazysite-dav.pl'         => 'WebDAV',
        'lazysite-mcp.pl'         => 'MCP',
        'lazysite-manager-api.pl' => 'Control API',
    );
    for my $file ( sort keys %CHANNEL ) {
        my $code = slurp("$root/$file");
        $code = join "\n", grep { !/^\s*#/ } split /\n/, $code;
        like( $code, qr/Lazysite::Auth::Acl::groups_for_user/,
            "$CHANNEL{$file} resolves groups from the shared resolver, as the "
                . 'table says' );
    }
    like( $REF, qr/groups_for_user/,
        'and the table names the resolver rather than describing it vaguely' );
    like( $REF, qr/X[-_]REMOTE[-_]GROUPS/i,
        'the cookie path is documented as the exception it is' );
};

# --- the truth table's load-bearing cell ------------------------------------
# The cell that was wrong for three releases.
subtest 'the truth table on the anonymous path' => sub {
    like( $REF, qr/Static file.*ACL store.*\|\s*\*\*ACL\*\*/,
        'a static IS governed by the ACL when the site has a store' );
    like( $PROC, qr/sub _acl_allows_read/,
        'and the processor carries the read decision that does it' );
    like( $REF, qr/No ACL store means no change|NO ACL store/,
        'and the no-store case is documented as unchanged' );
    like( $PROC, qr/return 1 unless keys %\$map/,
        'which is what the code does' );
};

# --- FEATURES carries the visitor-facing half -------------------------------
# It documented authoring permissions and was silent on "can a site limit who
# sees this", which is the question an operator actually asks.
subtest 'FEATURES states the visitor-facing capability' => sub {
    like( $FEAT, qr/Limiting who can see content/,
        'FEATURES has the visitor-facing section' );
    for my $claim (
        [ qr/whole site/i,            'the site-wide scope' ],
        [ qr/opt-in/i,                'that protection is opt-in' ],
        [ qr/\bdraft\b/i,             'the draft policy' ],
        [ qr/does not reach static/i, 'that auth_default does not cover assets' ],
        [ qr/check-acl/,              'how to verify it from outside' ],
        )
    {
        like( $FEAT, $claim->[0], "FEATURES states $claim->[1]" );
    }

    # The claim SM288 falsified must not come back.
    unlike( $FEAT, qr/\@group.*never matches it/i,
        'and no longer claims an @group can never match a partner' );
};

done_testing();
