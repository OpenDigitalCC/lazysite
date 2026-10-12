#!/usr/bin/perl
# SM887, from the release manager's real-session run (2026-10-12):
# site-context.md told the agent to write read_nav's answer to nav.conf and
# "see the format note below" - and there was no note. The agent was left to
# guess the format of a file it had only ever seen as JSON.
#
# The note now exists. This holds it to the parser: the example it gives parses
# to the structure it describes, and each rule it states is what parse_nav
# does. A note that drifted from the parser would be worse than none.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir tempfile);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root load_processor setup_minimal_site);

my $doc = repo_root() . '/skills/claude-ai/lazysite/reference/site-context.md';
plan skip_all => "no $doc" unless -f $doc;

my $text = do {
    open my $fh, '<', $doc or die "$doc: $!";
    local $/;
    <$fh>;
};

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);
load_processor($docroot);

sub parse {
    my ($content) = @_;
    my ( $fh, $path ) = tempfile( SUFFIX => '.conf', UNLINK => 1 );
    binmode $fh, ':utf8';
    print {$fh} $content;
    close $fh;
    return main::parse_nav($path);
}

my ($section) = $text =~ /^## The nav\.conf format\n(.*?)^## /ms;
ok( defined $section, 'site-context.md has the nav.conf format note' )
    or BAIL_OUT('no note to test');
my $c4_pos   = index( $text, '| C4 |' );
my $note_pos = index( $text, '## The nav.conf format' );
ok( $c4_pos >= 0 && $note_pos > $c4_pos, 'the note is BELOW the C4 row that points to it' );

subtest 'the example parses to the structure it shows' => sub {
    my ($example) = $section =~ /^```\n(.*?)^```/ms;
    ok( defined $example, 'the note carries an example' ) or return;
    my $nav = parse($example);
    is_deeply(
        $nav,
        [
            { label => 'Home',  url => '/',      children => [] },
            { label => 'About', url => '/about', children => [] },
            {   label    => 'Docs',
                url      => '/docs',
                children => [
                    { label => 'Install',   url => '/docs/install' },
                    { label => 'Configure', url => '/docs/configure' },
                ],
            },
            {   label    => 'Resources',
                url      => '',
                children => [ { label => 'Blog', url => '/blog' } ],
            },
        ],
        'top-level items, two-space children, a bare label as a heading'
    );
};

subtest 'each rule the note states is what the parser does' => sub {
    like( $section, qr/FIRST `\|`/, 'stated: split at the first |' );
    is( parse("A | /x?a|b\n")->[0]{url}, '/x?a|b', 'and a later | stays in the url' );

    like( $section, qr/ONE level only/, 'stated: one level of children' );
    my $deep = parse("Top | /t\n  Kid | /k\n      Deeper | /d\n");
    is( scalar @{ $deep->[0]{children} }, 2, 'a deeper indent is still a child of the top-level item' );

    like( $section, qr/no top-level line above it becomes a top-level item/, 'stated: an orphan child' );
    my $orphan = parse("  Lone | /l\nTop | /t\n");
    is( scalar @$orphan, 2, 'an indented first line is top-level' );
    is( $orphan->[0]{label}, 'Lone', 'and keeps its place' );

    like( $section, qr/first non-blank character makes a comment/, 'stated: comments' );
    my $c = parse("  # indented comment\nA # not a comment | /a\n\n");
    is( scalar @$c, 1, 'an indented # line is a comment and a blank line is skipped' );
    is( $c->[0]{label}, 'A # not a comment', 'a later # is part of the label' );

    like( $section, qr/no label \(`\| \/x`\) is dropped/, 'stated: no label, no item' );
    is_deeply( parse("| /x\n"), [], 'and it is dropped' );

    is( parse("Caf\x{e9} | /cafe\n")->[0]{label}, "Caf\x{e9}", 'read as UTF-8, as stated' );
};

done_testing();
