#!/usr/bin/perl
# The shipped operator templates must substitute cleanly.
#
# WHY. `docs/compliance/*-TEMPLATE.md` are filled in and SIGNED by operators.
# They use the document pipeline's variable substitution: a `vars:` map in the
# front matter fills every `{{name}}` placeholder in the document - prose,
# datatable rows, and the title itself.
#
# Two ways that goes wrong silently, both of which land on the operator rather
# than on us:
#
#   - a placeholder in the body with no entry in `vars:` stays literal and emits
#     a build warning. On a document whose whole purpose is to be signed as a
#     true statement, a stray `{{...}}` in the rendered PDF is worse than a
#     blank - it looks like a value.
#   - a `vars:` entry nothing references is a question the template asks the
#     operator to answer for no reason, which is how a form grows until people
#     stop reading it.
#
# So this asserts both directions. It is deliberately a lint rather than a note
# in the template, because the templates are edited by whoever adds an
# obligation, and the last four things this project found wrong were all
# hand-maintained correspondences nobody re-checked.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

my @templates = sort glob "$root/docs/compliance/*-TEMPLATE.md";
cmp_ok( scalar @templates, '>=', 2, 'found the operator templates' )
    or do { done_testing; exit };

for my $path (@templates) {
    ( my $name = $path ) =~ s{.*/}{};

    my $text = do {
        open my $fh, '<', $path or die "$path: $!";
        local $/;
        <$fh>;
    };

    subtest $name => sub {
        my ($fm) = $text =~ /\A---\n(.*?)\n---\n/s;
        ok( $fm, 'has front matter' ) or return;

        # The vars block, parsed without a YAML module: two-space-indented
        # `key: value` lines under `vars:`, which is the shape the template
        # uses and the shape an operator edits.
        # Match against "$fm\n": the front-matter capture stops before the
        # closing fence, so its final line carries no newline and a
        # line-anchored alternation would silently drop the LAST variable -
        # which is exactly the kind of off-by-one this lint exists to catch.
        my ($block) = "$fm\n" =~ /^vars:\n((?:[ \t]+\S.*\n|[ \t]*\n)*)/m;
        ok( $block, 'declares a vars: map' ) or return;
        my %declared = map { /^\s*(\w+)\s*:/ ? ( $1 => 1 ) : () }
            split /\n/, $block;
        cmp_ok( scalar keys %declared, '>=', 5,
            'and the map has entries' );

        my %used;
        $used{$1} = 1 while $text =~ /\{\{(\w+)\}\}/g;

        my @undefined = sort grep { !$declared{$_} } keys %used;
        is_deeply( \@undefined, [],
            'every placeholder in the document is declared in vars:' )
            or diag( join "\n  ",
            '',
            @undefined,
            '',
            'These stay literal in the rendered document and warn at build.',
            'On a document that gets SIGNED, a stray placeholder reads as a',
            'value. Either declare it, or stop referring to it.' );

        my @unused = sort grep { !$used{$_} } keys %declared;
        is_deeply( \@unused, [],
            'and every declared variable is actually used' )
            or diag( join "\n  ",
            '',
            @unused,
            '',
            'The template asks the operator for these and never uses the',
            'answer. Reference them or remove them.' );

        # The title is what names the rendered file, so a per-deployment render
        # that does not vary the title overwrites the previous one.
        like( $text, qr/^title:[^\n]*\{\{\w+\}\}/m,
            'the title carries a placeholder, so per-deployment renders do '
                . 'not overwrite each other' );
    };
}

done_testing();
