#!/usr/bin/perl
# SM1037 (WORK-PLAN-0154, P23's finding, ruled 2026-10-12 "Fix both"): the
# configuration docs' nav section described a YAML format - `- label: ...`,
# `url:`, `children:` - and parse_nav reads `Label | /url` lines. A nav written
# from the doc rendered as labels with no links.
#
# The docs now give the line format. This holds them to the parser: each doc's
# example parses to the structure it shows, each rule configuration.md states
# is what parse_nav does, and neither doc offers YAML as the format again.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root load_processor setup_minimal_site site_tempdir);

my $docroot = site_tempdir();
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

sub section {
    my ($name) = @_;
    my $doc = repo_root() . "/starter/docs/$name";
    open my $fh, '<:utf8', $doc or die "$doc: $!";
    my $text = do { local $/; <$fh> };
    close $fh;
    my ($s) = $text =~ /^## Navigation \(nav\.conf\)\n(.*?)^## /ms;
    return $s;
}

my $EXPECTED = [
    { label => 'Home',  url => '/',      children => [] },
    { label => 'About', url => '/about', children => [] },
    { label => 'Docs',
        url => '/docs',
        children => [ { label => 'Install', url => '/docs/install' }, { label => 'Authoring', url => '/docs/authoring' } ],
    },
    { label => 'Resources', url => '', children => [ { label => 'GitHub', url => 'https://github.com/example' } ] },
];

for my $name ( 'configuration.md', 'ai-briefing-configuration.md' ) {
    subtest "$name: the example is what the parser reads" => sub {
        my $s = section($name);
        ok( defined $s, 'the doc has a Navigation (nav.conf) section' ) or return;
        my ($example) = $s =~ /^```\n(.*?)^```/ms;
        ok( defined $example, 'it carries an example' ) or return;
        is_deeply( parse($example), $EXPECTED, 'which parses to links, a heading and one level of children' );
        unlike( $s, qr/^\s*-\s+label:/m, 'no YAML list is offered as the format' );
        unlike( $s, qr/```yaml/,         'no YAML block' );
    };
}

subtest 'each rule configuration.md states is what parse_nav does' => sub {
    my $s = section('configuration.md');
    like( $s, qr/split at the first `\|`/, 'stated: split at the first |' );
    is( parse("A | /x?a|b\n")->[0]{url}, '/x?a|b', 'and a later | stays in the address' );

    like( $s, qr/line with no `\|` is a heading/, 'stated: a bare label is a heading' );
    is_deeply( parse("Head\n"), [ { label => 'Head', url => '', children => [] } ], 'an item with no address' );

    like( $s, qr/One level only/, 'stated: one level of children' );
    my $deep = parse("Top | /t\n  Kid | /k\n      Deeper | /d\n");
    is( scalar @{ $deep->[0]{children} }, 2, 'a deeper indent is still a child of the top-level item' );

    like( $s, qr/no top-level line above it is a\s+top-level item/, 'stated: an orphan child' );
    my $orphan = parse("  Lone | /l\nTop | /t\n");
    is( scalar @{$orphan},   2,      'an indented first line is top-level' );
    is( $orphan->[0]{label}, 'Lone', '...and keeps its place' );

    like( $s, qr/first non-blank character makes the line a comment/, 'stated: comments' );
    my $c = parse("  # indented comment\nA # not a comment | /a\n\n");
    is( scalar @{$c}, 1, 'an indented # line is a comment and a blank line is skipped' );
    is( $c->[0]{label}, 'A # not a comment', 'a later # is part of the label' );

    like( $s, qr/no label \(`\| \/x`\) is dropped/, 'stated: no label, no item' );
    is_deeply( parse("| /x\n"), [], '...and it is dropped' );

    like( $s, qr/read as UTF-8/, 'stated: UTF-8' );
    is( parse("Caf\x{e9} | /cafe\n")->[0]{label}, "Caf\x{e9}", '...as it is read' );
};

done_testing();
