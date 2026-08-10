#!/usr/bin/perl
# Eight-dimension review D6 (security): run the security-themed Perl::Critic
# policies over the production set at severity 1 (the broadest), independent of
# the curated profile's exclusions. Green at introduction; the gate exists so a
# future security-flagged construct refuses the build rather than landing
# silently. Skips cleanly where perlcritic is not installed (host dev tool).
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

my @scripts = sort glob("$root/*.pl $root/tools/*.pl $root/plugins/*.pl $root/lib/Lazysite/*.pm $root/lib/Lazysite/*/*.pm");
ok( scalar @scripts, 'found production scripts to lint' );

# SM269 phase 1: sharded across forks. Second-slowest file in the suite at
# 31.7 s, and under `prove -j` the parallel run cannot finish faster than its
# slowest file. Same files, same theme, same severity - only the scheduling
# changes, because the gate must not start checking less than it did.
my $out = _critic_sharded( $root, \@scripts, '--theme security --severity 1' );
is( $out, '', 'no security-themed perlcritic violations at severity 1' )
    or diag("security violations:\n$out");

# Shared shape with t/lint/02: hand each of N children a slice of the file list,
# merge in shard order for a deterministic report, and treat a child that failed
# to run as a violation rather than as silence - an empty slice from a crashed
# shard would otherwise read as a clean sweep nobody performed.
sub _critic_sharded {
    my ( $root, $files, $args, $shards ) = @_;
    $shards ||= 4;
    my $tmp = File::Temp->newdir( 'lazysite-critsec-XXXXXX', TMPDIR => 1 );

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
            my $o    = `cd '$root' && perlcritic $args --quiet $list 2>&1`;
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
    $out .= join( "\n", '', @bad ) if @bad;
    return $out;
}


done_testing();
