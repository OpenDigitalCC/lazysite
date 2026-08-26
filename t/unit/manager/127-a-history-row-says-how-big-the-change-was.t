#!/usr/bin/perl
# SM629: each history row carries the size of that revision's change.
#
# The row said when, who and the subject - so judging which revision to open
# meant opening several. Lines added and removed answer "which one was the big
# edit" at a glance, and come from --numstat on the git log call the timeline
# ALREADY makes, so no extra process runs per revision.
#
# TWO THINGS THAT ARE NOT COSMETIC:
#
#   A binary file reports "-" for both counts. That arrives as undef and renders
#   as "binary", never as "+0 -0" - "nothing changed" and "not countable in
#   lines" are different answers and 0 states the wrong one confidently.
#
#   The numstat line arrives AFTER its commit line, so the walk defers its stop
#   by one record. Stopping on the commit line - the obvious way to write it -
#   would leave the LAST row of every page with no size, which is the row a
#   reader most often wants (the oldest shown, where a file was created).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";

my $root = "$FindBin::Bin/../../..";

# --- 1. the module reports the counts ---------------------------------------
SKIP: {
    eval { require Lazysite::Git; 1 } or skip 'no Lazysite::Git', 10;
    skip 'git not available', 10 unless Lazysite::Git::git_available();

    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite");
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$c} "git_history: enabled\n";
    close $c;

    my @g = ( "--git-dir=$d/lazysite/git", "--work-tree=$d" );
    system( 'git', @g, 'init', '-q' ) == 0 or skip 'git init failed', 10;
    system( 'git', @g, 'config', 'user.email', 't@t' ) == 0 or skip 'git config failed', 10;
    system( 'git', @g, 'config', 'user.name', 't' ) == 0 or skip 'git config failed', 10;

    sub commit {
        my ( $dir, $gr, $body, $msg ) = @_;
        open my $fh, '>', "$dir/a.md" or die $!;
        print {$fh} $body;
        close $fh;
        system( 'git', @$gr, 'add', 'a.md' );
        system( 'git', @$gr, 'commit', '-q', '-m', $msg );
    }
    commit( $d, \@g, "one\n",             'add a' );
    commit( $d, \@g, "one\ntwo\nthree\n", 'grow a' );
    commit( $d, \@g, "one\n",             'shrink a' );

    my $log = Lazysite::Git::file_log( $d, 'a.md', 10 );
    is( scalar @$log, 3, 'three revisions' ) or diag( explain $log );

    is( $log->[0]{added},   0, 'the shrink added nothing' );
    is( $log->[0]{removed}, 2, 'and removed two lines' );
    is( $log->[1]{added},   2, 'the grow added two' );

    # The boundary row. This is the one a naive stop-on-commit-line loses.
    is( $log->[2]{added}, 1,
        'the OLDEST entry still has its size - the walk defers its stop so the '
            . 'numstat line, which arrives after the commit line, is not cut off' );
    ok( defined $log->[2]{removed}, 'and its removed count' );

    # A BINARY revision, from the module rather than from hand-fed JSON. The
    # render half of this test covered "binary" and the module half did not, so
    # a sabotage that counted "-" as 0 in the parser passed: the UI would then
    # be told, confidently and wrongly, that nothing changed.
    open my $b, '>', "$d/pic.bin" or die $!;
    binmode $b;
    print {$b} pack( 'C*', 0, 1, 2, 255, 0, 3 );
    close $b;
    system( 'git', @g, 'add', 'pic.bin' );
    system( 'git', @g, 'commit', '-q', '-m', 'add a binary' );

    my $blog = Lazysite::Git::file_log( $d, 'pic.bin', 5 );
    ok( scalar @$blog, 'the binary file has a revision' );
    is( $blog->[0]{added},   undef, 'a binary revision reports no line count' );
    is( $blog->[0]{removed}, undef, 'for either direction' );
    is( $blog->[0]{binary},  1,     'and is flagged binary, so the row can say so' );
}

# --- 2. the row renders them ------------------------------------------------
SKIP: {
    chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
    skip 'node not installed', 6 unless length $node && -x $node;

    my $page = "$root/starter/manager/files.md";
    skip "no $page", 6 unless -f $page;
    my $src = do { open my $fh, '<', $page or die $!; local $/; <$fh> };
    my ($fn) = $src =~ /(function renderHistory\(panel, entries\).*?\n\})/s;
    ok( $fn, 'the history renderer is present' ) or skip 'no renderer', 5;

    my $dir = tempdir( CLEANUP => 1 );
    sub render {
        my ( $node, $dir, $fn, $entries ) = @_;
        open my $js, '>', "$dir/h.js" or die $!;
        print {$js} <<"JS";
function escHtml(x){return String(x==null?'':x);}
function absTime(e){return 'T'+e;}
var panel = { innerHTML: '' };
$fn
renderHistory(panel, $entries);
console.log(JSON.stringify({ html: panel.innerHTML }));
JS
        close $js;
        require JSON::PP;
        return JSON::PP::decode_json(`\Q$node\E \Q$dir/h.js\E 2>&1`);
    }

    my $r = render( $node, $dir, $fn,
        '[{sha:"a1",epoch:1,author:"me",subject:"grow",added:12,removed:3}]' );
    ok( $r, 'the renderer ran' ) or skip 'render failed', 4;
    like( $r->{html}, qr/\+12/,           'the row shows lines added' );
    like( $r->{html}, qr/&minus;3|-3/,    'and lines removed' );
    like( $r->{html}, qr/<th>Size<\/th>/, 'under a Size column' );

    # Binary: never "+0 -0".
    my $b = render( $node, $dir, $fn,
        '[{sha:"b1",epoch:1,author:"me",subject:"img",added:null,removed:null,binary:1}]' );
    like( $b->{html}, qr/binary/, 'a binary revision says so' );
    unlike( $b->{html}, qr/\+0/,
        'and never states a confident zero for something not countable in lines' );
}

done_testing();
