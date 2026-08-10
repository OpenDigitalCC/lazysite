#!/usr/bin/perl
# WP-1 (D1/D2 code quality): enforce the curated Perl::Critic profile
# (.perlcriticrc) over the production scripts at severity 3. The deliberately
# disabled policies are documented in the profile and in
# docs/architecture/code-quality.md. Skips cleanly where perlcritic is not
# installed - it is a host dev tool, not a runtime dependency.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);
use File::Temp ();

my $root = repo_root();
chomp( my $critic = `which perlcritic 2>/dev/null` );
plan skip_all => 'perlcritic not installed' unless $critic;
plan skip_all => 'no profile'               unless -f "$root/.perlcriticrc";

my @scripts = sort glob("$root/*.pl $root/tools/*.pl $root/plugins/*.pl $root/lib/Lazysite/*.pm $root/lib/Lazysite/*/*.pm");
ok( scalar @scripts, 'found production scripts to lint' );

# SM269 phase 1: SHARDED across forks, not one invocation.
#
# This file was the slowest in the suite at 41.3 s - 11% of the plain run on its
# own, and with `prove -j` it is the critical path: the whole parallel suite
# cannot finish faster than its slowest single file. perlcritic is
# single-threaded over a file list, so the fix is to hand each of N children a
# slice and merge the output.
#
# The CHECK IS UNCHANGED: same files, same profile, same severity. Only the
# scheduling differs, which matters because the release gate must not quietly
# start checking less than it did.
my $out = _critic_sharded( $root, \@scripts );
is( $out, '', 'all production scripts pass the lazysite perlcritic profile (severity 3)' )
    or diag("perlcritic violations:\n$out");


# Run perlcritic over @$files in $shards parallel children, returning the
# concatenated violation output (empty means clean).
#
# Each child writes to its own file and exits; the parent waits for all of them
# and concatenates in shard order, so the report is deterministic regardless of
# which child finishes first. A child that dies without writing leaves an empty
# slice, which would silently pass - so the parent checks every child's exit
# status and reports a failure as a violation line rather than as silence.
sub _critic_sharded {
    my ( $root, $files, $shards ) = @_;
    $shards ||= 4;
    my $tmp = File::Temp->newdir( 'lazysite-critic-XXXXXX', TMPDIR => 1 );

    my @slice;
    my $i = 0;
    push @{ $slice[ $i++ % $shards ] }, $_ for @$files;

    my %pid;
    for my $n ( 0 .. $#slice ) {
        next unless $slice[$n] && @{ $slice[$n] };
        my $pid = fork;
        die "fork failed: $!" unless defined $pid;
        if ( !$pid ) {
            my $list = join ' ', map { "'$_'" } @{ $slice[$n] };
            my $o = `cd '$root' && perlcritic --profile '$root/.perlcriticrc' --quiet $list 2>&1`;
            open my $fh, '>', "$tmp/$n" or exit 2;
            print {$fh} $o;
            close $fh;
            exit 0;
        }
        $pid{$pid} = $n;
    }

    my @bad;
    while ( my $pid = wait ) {
        last if $pid < 0;
        my $n = delete $pid{$pid};
        next unless defined $n;
        push @bad, "shard $n exited " . ( $? >> 8 ) if $? != 0;
    }

    my $out = '';
    for my $n ( 0 .. $#slice ) {
        next unless $slice[$n] && @{ $slice[$n] };
        if ( open my $fh, '<', "$tmp/$n" ) {
            local $/;
            $out .= <$fh> // '';
            close $fh;
        }
        else {
            push @bad, "shard $n produced no output file";
        }
    }
    # A shard that failed to run is NOT a pass. Fold it into the violation text
    # so the assertion fails loudly rather than reporting a clean sweep it did
    # not perform.
    $out .= join( "\n", '', @bad ) if @bad;
    return $out;
}

done_testing();
