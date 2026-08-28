#!/usr/bin/perl
# SM652: the control API served live submissions to `manage_forms`; MCP
# required `read_submissions` for the same data.
#
# Measured by the site agent 2026-08-26: the same token, in the same minute,
# read submissions over one channel while `tools/list` did not even offer the
# tool on the other. Both registries were internally consistent; they simply
# gave different answers to "who may read a form submission", and a submission
# is personal data.
#
# THE DIVERGENCE WAS DOCUMENTED IN THE WRONG PLACE. form_list's description
# said "Needs read_submissions (a least-privilege read; the control API also
# accepts manage_forms)" - documenting the control API's rule, on MCP, in the
# description of a tool the caller was not offered. An operator granting
# manage_forms and reading MCP concluded the capability was definition-only;
# the same operator reading the control API found it read live submissions.
# Neither was wrong about the surface they read.
#
# The release manager chose to narrow the API, so manage_forms is genuinely
# definition-only and reading a submission always needs the least-privilege
# capability built for it.
#
# form-list is narrowed too, because it returns row_count - whether a form has
# submissions and how many - which is a read of submission EXISTENCE even
# though it carries no content. MCP has always treated it that way.
#
# THE CREDENTIAL IS THE POINT: manage_forms WITHOUT read_submissions. A test
# using a grant that holds both proves nothing about which one opened the door.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $api  = do {
    open my $fh, '<', "$root/lazysite-manager-api.pl" or die $!;
    local $/;
    <$fh>;
};
my $mcp = do {
    open my $fh, '<', "$root/lazysite-mcp.pl" or die $!;
    local $/;
    <$fh>;
};

# The gate predicates, read from the table rather than from prose about it.
my ($need) = $api =~ /\n( *my %need = \(.*?\n *\);)/s;
ok( $need, 'the token gate table was found' )
    or BAIL_OUT('no %need - nothing below compares anything');
my ($cookie) = $api =~ /\n( *my %COOKIE_CAP = \(.*?\n *\);)/s;
ok( $cookie, 'the cookie gate table was found' ) or BAIL_OUT('no %COOKIE_CAP');

for my $t ( [ 'token', $need ], [ 'cookie', $cookie ] ) {
    my ( $which, $tbl ) = @{$t};
    for my $act (qw(form-submissions form-list)) {
        my ($line) = $tbl =~ /^\s*'\Q$act\E'\s*=>\s*(.+)$/m;
        ok( defined $line, "$which gate names $act" ) or next;
        like( $line, qr/read_submissions/,
            "$which: $act needs read_submissions" );
        unlike( $line, qr/manage_forms/,
            "$which: $act does NOT accept manage_forms - the capability is "
                . "definition-only now" );
    }
}

# --- SM660: and the DESTRUCTIVE verbs need the read they destroy ------------
# SM652 narrowed the reads above and left three verbs on manage_forms alone, so
# a grant could delete a submission row and clear a quarantine flag while unable
# to read either - destroying personal data it may not see, often the only copy.
# The release manager's decision (2026-08-28): both capabilities.
#
# `a+b` in %COOKIE_CAP means BOTH, beside the existing `a|b` meaning either.
# Asserted on the separator, because `manage_forms|read_submissions` would look
# almost identical here and mean the opposite - either would do.
for my $act (
    qw(form-submission-delete form-submission-confirm form-submissions-delete-bulk) )
{
    my ($line) = $cookie =~ /^\s*'\Q$act\E'\s*=>\s*(.+)$/m;
    ok( defined $line, "cookie gate names $act" ) or next;
    like( $line, qr/manage_forms\+read_submissions/,
        "$act needs manage_forms AND read_submissions" )
        or diag( 'A `|` here would mean EITHER capability suffices, which is '
            . 'the defect rather than the fix.' );
}

# --- and MCP is unchanged, because it was already right ---------------------
# If this had drifted the other way the channels would agree at the wrong
# value, and every assertion above would still pass.
for my $tool (qw(form_list read_form_submissions)) {
    my ($body) = $mcp =~ /^\s{4}\Q$tool\E\s*=>\s*\{(.*?)^\s{4}\},/ms;
    ok( defined $body, "MCP declares $tool" ) or next;
    like( $body, qr/cap\s*=>\s*'read_submissions'/,
        "MCP: $tool still requires read_submissions" );
}

# --- SM594: and the capability's OWN description agrees with its gate --------
# SM652 narrowed the gate and updated the comment ABOVE the description while
# leaving the description itself saying this capability "returns live submission
# CONTENT". It shipped in 0.11.3 that way. That sentence is what an operator
# reads when deciding whether to hand the grant over, and it overstated the
# reach - the direction that causes over-granting, because a sysop reading it
# reaches for read_submissions when manage_forms would have done.
#
# Structural lints did not catch it: they compare `unlocks` against the gate,
# and this is prose. So it is asserted here, on the claim specifically.
{
    my $caps = do {
        open my $fh, '<', "$root/lib/Lazysite/Capabilities.pm" or die $!;
        local $/;
        <$fh>;
    };
    my ($mf) = $caps =~ /^\s{4}manage_forms\s*=>\s*\{(.*?)^\s{4}\},/ms;
    ok( defined $mf, 'manage_forms declares itself in Capabilities.pm' );
    my ($title) = $mf =~ /title\s*=>\s*(.*?)(?:^\s+\w+\s*=>)/ms;
    $title //= '';
    unlike( $title, qr/returns live\s+.\s*.\s*submission CONTENT/s,
        'the description no longer claims this grant returns submission content' );
    unlike( $title, qr/AND read what has been/,
        'nor that it reads what was submitted' )
        or diag( 'SM652 removed that reach; a description that still promises '
            . 'it tells a sysop the grant is wider than it is.' );
    like( $title, qr/does NOT read submissions/,
        'and says plainly that it does not' );
}

# --- the description that documented the divergence -------------------------
# It described the control API's rule on the surface that did not implement
# it. With the rule gone, the sentence is not merely stale - it tells a reader
# the opposite of what both channels now do.
my ($fl) = $mcp =~ /^\s{4}form_list\s*=>\s*\{(.*?)^\s{4}\},/ms;
unlike( $fl // '', qr/control API also accepts manage_forms/,
    'the note describing the divergence is gone - the channels agree, and a '
        . 'stale sentence about the old rule would now be actively wrong' );

done_testing();
