#!/usr/bin/perl
# SM887 F2: page validation is something the ENGINE offers, so anything can ask.
#
# The checks themselves are not new - they are the ones that lived inside
# lazysite-mcp.pl. What is new is that they can be CALLED: by this test, by the
# CLI, by CI, by a pre-commit hook, by the claude.ai skill that has a container
# and a file and no site. This file pins the part that makes that possible.
#
# THE THREE THINGS THAT COULD SILENTLY REGRESS:
#   1. a page with an issue is NOT valid, and a page with only warnings IS -
#      the whole severity contract, and the reason a gate on this is usable;
#   2. the two checks that need a site say they could not check, rather than
#      passing - a check that skips silently is a check that always passes;
#   3. severity and file travel ON the message, so a caller gathering messages
#      from twenty pages does not have to remember which array each came from.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);
use lib repo_root() . '/lib';
use Lazysite::Validate qw(validate_content validate_file);

subtest 'an issue makes a page invalid' => sub {
    my $r = validate_content( content => "---\ntitle: T\n\nnever closed\n" );
    ok( !$r->{valid}, 'unterminated front matter is an ISSUE' );
    is( scalar @{ $r->{issues} }, 1,                           'one issue' );
    is( $r->{issues}[0]{kind},    'front-matter-unterminated', 'named' );
};

subtest 'warnings alone leave a page valid' => sub {
    # A page with no title and a phone number is poor and publishable. If this
    # ever became invalid, `lazysite validate && publish` would refuse pages
    # their authors meant - and people would stop running it.
    my $r = validate_content( content => "---\nfoo: bar\n---\n\nCall 01234 567890.\n" );
    ok( $r->{valid},                     'still valid' );
    ok( scalar @{ $r->{warnings} } >= 2, 'but it warned' )
        or diag( 'got: ' . join( ', ', map { $_->{kind} } @{ $r->{warnings} } ) );
    is_deeply( $r->{issues}, [], 'and nothing was raised as an issue' );
};

subtest 'severity and file are fields on the message' => sub {
    my $r = validate_content(
        content => "---\ntitle: T\n\nbroken\n",
        file    => 'pages/thing.md',
    );
    is( $r->{issues}[0]{severity}, 'issue',          'an issue says so' );
    is( $r->{issues}[0]{file},     'pages/thing.md', 'and carries the file' );
    my $w = validate_content( content => "no front matter at all\n" );
    is( $w->{warnings}[0]{severity}, 'warning', 'a warning says so' );
    ok( !exists $w->{warnings}[0]{file},
        'and no file is invented when the caller gave none' );
};

subtest 'a check that needs a site says it could not run' => sub {
    # THE POINT OF THE WHOLE ITEM. Validating a file in isolation cannot read
    # the table descriptors. Reporting nothing would be a pass the page has not
    # earned.
    my $page        = "---\ntitle: T\nrows: db:events\n---\n\nbody\n";
    my $r           = validate_content( content => $page );
    my ($unchecked) = grep { $_->{kind} eq 'db-binding-unchecked' } @{ $r->{warnings} };
    ok( $unchecked, 'the db: binding is reported as UNCHECKED, not as fine' );
    like( $unchecked->{message}, qr/no site was given/,
        'and the message says why, so the reader can re-run it properly' );
};

subtest 'given a site, the same check actually runs' => sub {
    # The discriminating half: if the message above appeared whether or not a
    # docroot was passed, the parameter would be decoration.
    my $d = site_tempdir();
    my $r = validate_content(
        content => "---\ntitle: T\nrows: db:events\n---\n\nbody\n",
        docroot => $d,
    );
    my ($unchecked) = grep { $_->{kind} eq 'db-binding-unchecked' } @{ $r->{warnings} };
    ok( !( $unchecked && $unchecked->{message} =~ /no site was given/ ),
        'with a docroot it does not report "no site was given"' )
        or diag('The docroot was ignored, so every site-aware check is dead.');
};

subtest 'a file that cannot be read is an issue, not a die' => sub {
    # A run over twenty pages reports the one it could not open and carries on.
    my $r = validate_file('/nonexistent/definitely/not/here.md');
    ok( !$r->{valid}, 'invalid' );
    is( $r->{issues}[0]{kind}, 'unreadable', 'and says which page it was' );
    is( $r->{issues}[0]{file}, '/nonexistent/definitely/not/here.md', 'by name' );
};

# SM921: a pattern a browser cannot compile is REFUSED here - at the moment the
# author is writing the page - and only WARNED by `lazysite check`, which finds the
# ones already published. The render path is untouched on purpose: a render-time
# refusal would put an error where a form used to be, on upgrade, on exactly the
# sites that already have a bad pattern.
subtest 'an uncompilable form pattern makes the page invalid' => sub {
    my $page = "---\ntitle: T\nform: contact\n---\n\n:::form\n"
        . "phone | Phone | tel pattern:[0-9 ()+.-]{6,30}\n:::\n";
    my $r = validate_content( content => $page );
    ok( !$r->{valid}, 'the page is refused' );
    my ($issue) = grep { $_->{kind} eq 'uncompilable-pattern' } @{ $r->{issues} };
    ok( $issue, 'with its own kind, not lumped in with an unknown rule' );
    like( $issue->{message}, qr/\bphone\b/, 'naming the field' );
    like( $issue->{message}, qr/validates nothing/,
        'and the consequence, which is the part an author cannot see: a broken '
            . 'pattern is IGNORED, so the field accepts anything' );
};

subtest 'a pattern that compiles is left alone' => sub {
    for my $pat ( '[0-9\s\(\)\+\.\-]{6,30}', '.{2,}', '[A-Z]{2}[0-9]{4}' ) {
        my $page = "---\ntitle: T\nform: contact\n---\n\n:::form\n"
            . "ref | Reference | pattern:$pat\n:::\n";
        my $r = validate_content( content => $page );
        my ($issue) = grep { $_->{kind} eq 'uncompilable-pattern' } @{ $r->{issues} };
        ok( !$issue, "accepted: $pat" )
            or diag( 'A false refusal rejects a page that renders correctly, and '
                . 'the author has no way to tell they were refused for nothing.' );
    }
};

subtest 'the pattern is read to the end of the line, as the renderer reads it' => sub {
    # The space in this pattern is the whole point: if this check tokenised on
    # whitespace it would see `[0-9` - which compiles - and pass a page the browser
    # will refuse. A checker that reads a different page from the one that renders
    # is worse than no checker.
    my $page = "---\ntitle: T\nform: contact\n---\n\n:::form\n"
        . "phone | Phone | tel pattern:[0-9 ()+.\\-]{6,30}\n:::\n";
    my $r = validate_content( content => $page );
    my ($issue) = grep { $_->{kind} eq 'uncompilable-pattern' } @{ $r->{issues} };
    ok( $issue, 'the parentheses after the space are seen' );
};

subtest 'the MCP surface and this module give the same answer' => sub {
    # There is ONE implementation now. If lazysite-mcp.pl grew its own copy of a
    # check again, this is the assertion that would notice.
    my $src = do {
        open my $fh, '<', repo_root() . '/lazysite-mcp.pl' or die $!;
        local $/;
        <$fh>;
    };
    like( $src, qr/Lazysite::Validate::validate_content\(/,
        'the MCP validator calls the module' );
    unlike( $src, qr/^sub _check_(?:front_matter|fences|public_data)\b/m,
        'and keeps no second copy of the checks' )
        or diag( 'Two implementations of a check is two answers to "is this '
            . 'page all right", and only one of them gets fixed.' );
};

done_testing();
