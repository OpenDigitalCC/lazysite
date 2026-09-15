#!/usr/bin/perl
# SM887 F2 / A4: `lazysite validate` exits NON-ZERO on a broken page.
#
# THE EXIT STATUS IS THE ITEM, not a detail of it. Every validation surface in
# this tree answered ok:1 and exited 0 no matter how broken the page was -
# HTTP 200 over MCP, exit 0 everywhere else - so `validate && publish` could
# not be written and no pipeline could gate on it. SM887's acceptance criterion
# A4 says so in one line: "a deliberately broken page exits non-zero".
#
# WARNINGS DO NOT FAIL IT, and that is deliberate. A warning is a judgement the
# author may have made on purpose; a gate that fails on those is a gate people
# learn to bypass, which costs more than it saves. --strict is there for the
# caller who wants them counted, and this file pins both halves - a flag that
# changed nothing would pass any test that only ran it one way.
#
# Driven through the CLI as a subprocess, because the exit status of a
# subprocess is the thing under test and a function call cannot show it.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $root = repo_root();
my $tool = "$root/tools/lazysite-validate.pl";
my $cli  = "$root/tools/lazysite-cli.pl";
plan skip_all => "no validate tool at $tool" unless -f $tool;

my $d = site_tempdir();

sub write_page {
    my ( $name, $text ) = @_;
    open my $fh, '>', "$d/$name" or die $!;
    print {$fh} $text;
    close $fh;
    return "$d/$name";
}

my $clean = write_page( 'clean.md', "---\ntitle: Clean\n---\n\nA paragraph.\n" );
my $warny = write_page( 'warny.md', "---\ntitle: W\n---\n\n::: hero\nunclosed\n" );
my $broke = write_page( 'broke.md', "---\ntitle: B\n\nfront matter never closed\n" );

sub run {
    my (@args) = @_;
    my $out = qx($^X \Q$tool\E @{[ map { qq('$_') } @args ]} 2>&1);
    return ( $? >> 8, $out );
}

subtest 'a clean page exits 0' => sub {
    my ( $rc, $out ) = run($clean);
    is( $rc, 0, 'exit 0' );
    like( $out, qr/0 issue\(s\), 0 warning\(s\)/, 'and says it found nothing' );
};

subtest 'a broken page exits 1' => sub {
    my ( $rc, $out ) = run($broke);
    is( $rc, 1, 'exit 1 - SM887 A4' )
        or diag( 'Without this, `lazysite validate && publish` cannot be '
            . 'written and the whole capability is advisory.' );
    like( $out, qr/ISSUE: front-matter-unterminated/, 'and names what is wrong' );
};

subtest 'warnings alone do not fail it, unless asked' => sub {
    my ( $rc, $out ) = run($warny);
    is( $rc, 0, 'a page with only warnings exits 0' );
    like( $out, qr/WARNING: component-fence-unmatched/, 'the warning is still reported' );

    my ( $src, undef ) = run( '--strict', $warny );
    is( $src, 1, 'and --strict makes the same page exit 1' )
        or diag('A --strict that changes nothing is a flag that lies.');
};

subtest 'the line number points at the fence' => sub {
    # SM488's lesson, re-pinned here because this surface is new: a warning that
    # points at the wrong line reads as a broken tool.
    my ( undef, $out ) = run($warny);
    like( $out, qr/warny\.md:5:/, 'file:line, counted from the top of the FILE' );
};

subtest '--json is parseable and carries the counts' => sub {
    my ( $rc, $out ) = run( '--json', $broke );
    is( $rc, 1, 'still exit 1' );
    my $j = eval { decode_json($out) };
    ok( $j, 'parses as JSON' ) or diag($out);
    is( $j->{issues}, 1, 'one issue counted' );
    ok( !$j->{valid}, 'and the whole run is not valid' );
    is( $j->{files}[0]{issues}[0]{severity},
        'issue', 'severity travels on the message' );
};

subtest 'bad usage is 2, not 1' => sub {
    # An operator scripting this needs to tell "your page is wrong" from "your
    # command is wrong"; one exit status for both is how a typo reads as a
    # content failure.
    my ( $rc, undef ) = run('--nonsense');
    is( $rc, 2, 'unknown option exits 2' );
    my ( $none, undef ) = run();
    is( $none, 2, 'and so does naming no file' );
};

subtest 'the verb reaches it through the lazysite CLI' => sub {
    my $out = qx($^X \Q$cli\E validate \Q$broke\E 2>&1);
    my $rc  = $? >> 8;
    is( $rc, 1, '`lazysite validate` passes the status through' )
        or diag( 'A wrapper that swallows the child status undoes the point '
            . 'of having one.' );
    like( $out, qr/front-matter-unterminated/, 'and the output with it' );
};

done_testing();
