#!/usr/bin/perl
# SM1246: a test runs its child processes through TestHelper::run_child.
#
# THE CLASS. t/unit/dav/33 sat 95 minutes in the 2026-10-20 14:30 suite run on a
# lazysite-dav.pl child. 232 files under t/ had their own open3 or open2, 381 in
# all: write stdin, read stdout to EOF, then stderr (or never), then waitpid -
# with no limit anywhere. A child that fills one pipe while the test waits on
# another deadlocks the two; a child that never exits hangs the test, and nothing
# names it until the run's own five-hour limit. SM1245 moved them onto
# run_child, which serves the three pipes together and fails the test by name
# after a timeout. This keeps the next copy from coming back.
#
# WHAT THIS HOLDS. No file under t/ but TestHelper.pm itself (and the vendored
# t/vendor/) calls open2 or open3, unless a comment within the six lines before
# says the test DRIVES THE CHILD ITSELF - it signals the child, or reads it while
# it runs, and so needs the pid. Such a test bounds itself with feed_child and
# reap_child, as t/unit/dav/33 and t/tools/200 do.
#
# A source scan, line by line, comments skipped; a spawn in a string (a driver
# script a test writes) counts as one in code. It proves it still finds the old
# shape by running on it.
use strict;
use warnings;
use Test::More;
use File::Find;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# Returns the line numbers of each spawn in $source that is not declared.
sub findings {
    my ($source) = @_;
    my @l = split /\n/, $source;
    my @hit;
    for my $i ( 0 .. $#l ) {
        next if $l[$i] =~ /^\s*#/;
        next unless $l[$i] =~ /\bopen[23]\s*\(/;
        my $from = $i < 6 ? 0 : $i - 6;
        next if grep { /#.*drives the child itself/i } @l[ $from .. $i ];
        push @hit, $i + 1;
    }
    return @hit;
}

# The scan must still see the shape that was the bug.
{
    my $old = <<'OLD';
    my ( $wtr, $rdr );
    my $err = Symbol::gensym();
    my $pid = IPC::Open3::open3( $wtr, $rdr, $err, $^X, $script );
    print {$wtr} $body;
    close $wtr;
    my $out  = do { local $/; <$rdr> };
    my $eout = do { local $/; <$err> };
    waitpid $pid, 0;
OLD
    is_deeply( [ findings($old) ], [3], 'finds the open3 run_dav had' );
    is_deeply( [ findings('my $pid = open2( $o, $i, $^X, $tool );') ], [1], 'and an open2' );
    is_deeply( [ findings("# It drives the child itself: it signals it.\nmy \$pid = open3( \$in, \$o, \$e, \@cmd );") ],
        [], 'a spawn that says it drives the child itself is not a finding' );
    is_deeply( [ findings('# my $pid = open3( $w, $r, $e, @cmd );') ], [], 'nor is a comment' );
    is_deeply( [ findings('my $r = run_child( [ $^X, $tool ], stdin => $body );') ], [], 'nor is run_child' );
}

my @files;
find(
    {   wanted => sub {
            $File::Find::prune = 1 if $File::Find::name eq "$root/t/vendor";
            push @files, $File::Find::name if /\.(?:t|pm|pl)\z/ && -f;
        },
        no_chdir => 1,
    },
    "$root/t"
);
@files = grep { !m{/t/lib/TestHelper\.pm\z} && !m{/\Q$FindBin::Script\E\z} } sort @files;
cmp_ok( scalar @files, '>', 500, 'the scan sees the test tree' );

my @bad;
for my $f (@files) {
    open my $fh, '<', $f or die "$f: $!";
    my $src = do { local $/; <$fh> };
    close $fh;
    ( my $rel = $f ) =~ s{^\Q$root\E/}{};
    push @bad, map {"$rel:$_"} findings($src);
}
is( "@bad", '', 'every test child runs through run_child, or says why it cannot' )
    or diag( "Use TestHelper::run_child( [ \@argv ], stdin => ..., stderr => ... ).\n"
        . "A test that signals its child or reads it while it runs says so in a comment\n"
        . "('drives the child itself') and bounds itself with feed_child and reap_child." );

done_testing();
