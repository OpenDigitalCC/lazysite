#!/usr/bin/perl
# SM1302: a test's one-way pipe runs through TestHelper::run_child too.
#
# THE CLASS. SM1245 moved every two-way open2/open3 spawn under t/ onto
# run_child, and t/lint/273 holds that. It left 58 one-way pipe opens in 54
# files - open '-|' to read a child, '|-' to feed one, mostly git, find, tar and
# the tools under test - with no limit anywhere. They cannot deadlock on a second pipe,
# but a child that never exits still hangs the test in its read or its close,
# and nothing names it until the run's own five-hour limit. SM1301 moved them
# onto run_child, which ends the wait after child_timeout() and fails the test
# naming itself and the child. This keeps the next one from coming back.
#
# WHAT THIS HOLDS. No file under t/ but TestHelper.pm itself (and the vendored
# t/vendor/) opens a pipe to or from a child - the three-argument '-|' and '|-'
# modes, the forking open with no command, and the two-argument 'cmd |' and
# '| cmd' - unless a comment within the six lines before says why, in the words
# t/lint/273 uses: the test DRIVES THE CHILD ITSELF. A pipe open that is not a
# spawn at all, only text a fixture holds, says it is FIXTURE TEXT.
#
# A source scan, line by line, comments skipped; a pipe open in a string (a
# driver script a test writes) counts as one in code, as in t/lint/273. It
# proves it still finds the old shapes by running on them.
use strict;
use warnings;
use Test::More;
use File::Find;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# open, a handle (lexical, bareword or glob, escaped when it sits in a string),
# then a mode that starts or ends with the pipe.
my $PIPE_OPEN = qr{
    \bopen\s*\(?\s*(?:my\s+|our\s+|local\s+)?\\?[\$*]?\w+\s*,\s*
    (['"])(?:\s*\|[^'"]*|[^'"]*\|\s*)\1
}x;

# Returns the line numbers of each pipe open in $source that is not declared.
sub findings {
    my ($source) = @_;
    my @l = split /\n/, $source;
    my @hit;
    for my $i ( 0 .. $#l ) {
        next if $l[$i] =~ /^\s*#/;
        next unless $l[$i] =~ $PIPE_OPEN;
        my $from = $i < 6 ? 0 : $i - 6;
        next if grep { /#.*(?:drives the child itself|fixture text)/i } @l[ $from .. $i ];
        push @hit, $i + 1;
    }
    return @hit;
}

# The scan must still see the shapes that were the bug.
{
    my $old = <<'OLD';
sub git {
    my ( $d, @a ) = @_;
    open my $ph, '-|', 'git', '-C', $d, @a or die "git @a: $!";
    my $o = do { local $/; <$ph> } // '';
    close $ph;
    return $o;
}
OLD
    is_deeply( [ findings($old) ], [3], "finds the '-|' git helper five tools tests had" );
    is_deeply( [ findings(qq{open my \$ph, '|-',\n    "\$^X \\Q\$TOOL\\E --api > \$d/.out" or die \$!;}) ],
        [1], "and a '|-' feeding a child" );
    is_deeply( [ findings(q{my $pid = open my $ph, '-|';}) ],       [1], 'and the forking open' );
    is_deeply( [ findings(q{open( my $fh, "-|", 'sh', '-c', $c );}) ], [1], 'in parentheses, double-quoted' );
    is_deeply( [ findings(q{open PH, "git log |" or die;}) ],       [1], "and the two-argument 'cmd |'" );
    is_deeply( [ findings(q{open my $z, '| gzip > out.gz';}) ],     [1], "and '| cmd'" );
    is_deeply( [ findings(q{open my \$p, '|-', \$^X, '$tool', \@ARGV or die \$!;}) ],
        [1], 'and one in a driver script a test writes' );
    is_deeply( [ findings("# It drives the child itself: it signals it.\nopen my \$ph, '-|', \@cmd;") ],
        [], 'a pipe that says it drives the child itself is not a finding' );
    is_deeply( [ findings("# Fixture text: the file the tool classifies.\nmy \$t = \"open my \\\$fh, '-|', 'true';\";") ],
        [], 'nor is fixture text that says so' );
    is_deeply( [ findings(q{# open my $ph, '-|', 'git', 'log';}) ], [], 'nor is a comment' );
    is_deeply( [ findings(q{open my $fh, '<', $path or die $!;}) ], [], 'nor is a read of a file' );
    is_deeply( [ findings(q{open my $fh, '>>', 'a|b.log' or die $!;}) ], [], 'nor a file whose name has a bar' );
    is_deeply( [ findings(q{my $o = run_child( [ 'git', '-C', $d, @a ], stderr => 'inherit' )->{out};}) ],
        [], 'nor is run_child' );
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
is( "@bad", '', 'every pipe to or from a test child runs through run_child, or says why it cannot' )
    or diag( "Use TestHelper::run_child( [ \@argv ], stderr => 'inherit' )->{out} to read a child,\n"
        . "and stdin => \$bytes to feed one. A test that signals its child or reads it while it\n"
        . "runs says so in a comment ('drives the child itself') and bounds itself with\n"
        . "feed_child and reap_child; text a fixture holds says it is 'fixture text'." );

done_testing();
