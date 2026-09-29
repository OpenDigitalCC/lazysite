#!/usr/bin/perl
# SM914: A TEST NUMBER IS A LABEL, NOT AN IDENTIFIER - and the set of ambiguous
# ones only comes down.
#
# Measured 2026-09-29: 107 numbers name two or more test files, one names four,
# and 1,294 bare-number citations in the tree point at those 107. Nothing is
# broken - the harness globs filenames and both files run - but this project
# cites evidence by test number constantly, and a citation that reaches two
# different tests has stopped identifying anything.
#
# RULED 2026-09-29: write the convention down, and gate new ones. Not renumber.
# A rename invalidates every citation that names the file in FULL as well as
# every bare-number one, so the cure is larger than the disease for a property no
# code depends on. The convention is in docs/development.md; this is the gate.
#
# WHY A SET AND NOT A COUNT. A bare ceiling of 107 would let one collision be
# traded for another - resolve an old one, add a new one, and the number holds
# while the tree is no better. The baseline below names each colliding number, so
# a NEW collision fails even when the total is unchanged, and an entry that has
# stopped colliding ALSO fails, because a baseline nobody prunes stops describing
# the tree it claims to describe.
#
# HOW TO FIX A FAILURE: give the new test a number no other file in that
# directory uses. `ls t/<dir> | sed 's/-.*//' | sort -n | tail -1` is the highest
# in use. If you resolved an old collision instead, delete its line from the
# __DATA__ block at the foot of this file.
use strict;
use warnings;
use Test::More;
use File::Find;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# Each directory is its own numbering space, because the directory is part of how
# a test is cited. Leading zeros are not part of the number: `06-preview.t` and
# `6-deny.t` collide, and a citation written either way reaches both.
my %space;
find(
    {   no_chdir => 1,
        wanted   => sub {
            return unless /\.t\z/;
            my $rel = $File::Find::name;
            $rel =~ s{\A\Q$root\E/}{};
            return unless $rel =~ m{\At/};
            my ( $dir, $file ) = $rel =~ m{\A(.*)/([^/]+)\z};
            return unless defined $dir && $file =~ /\A(\d+)/;
            push @{ $space{$dir}{ 0 + $1 } }, $file;
        },
    },
    "$root/t"
);

my %now;
for my $dir ( sort keys %space ) {
    for my $n ( keys %{ $space{$dir} } ) {
        next unless @{ $space{$dir}{$n} } > 1;
        $now{"$dir/$n"} = [ sort @{ $space{$dir}{$n} } ];
    }
}

my %known = map { $_ => 1 } grep { length } map { s/\s+\z//r } <DATA>;

# THE RIG HAS TO SEE A COLLISION AT ALL. An empty %now would pass both
# assertions below against any baseline, which is the shape of a gate that has
# quietly stopped looking at anything.
cmp_ok( scalar keys %now, '>=', 2,
    'the scan finds collisions to reason about (' . scalar( keys %now ) . ')' )
    or diag( 'No collisions found at all - the scan is not reaching t/, so '
        . 'neither assertion below means anything.' );

my @new = sort grep { !$known{$_} } keys %now;
is_deeply( \@new, [], 'no test number has become ambiguous that was not already' )
    or diag( "A new test reuses a number its directory already had.\n"
        . join( "\n",
        map { "  $_ names: " . join( ', ', @{ $now{$_} } ) } @new )
        . "\nGive it a number nothing else in that directory uses." );

my @gone = sort grep { !$now{$_} } keys %known;
is_deeply( \@gone, [], 'the baseline names only numbers that are still ambiguous' )
    or diag( "These no longer collide, so delete them from the __DATA__ block:\n"
        . join( "\n", map {"  $_"} @gone )
        . "\nA baseline nobody prunes stops describing the tree." );

done_testing();

__DATA__
t/integration/5
t/integration/6
t/integration/13
t/integration/14
t/integration/16
t/integration/17
t/integration/18
t/integration/44
t/integration/45
t/integration/50
t/integration/51
t/integration/52
t/integration/53
t/integration/54
t/integration/55
t/integration/57
t/integration/58
t/integration/59
t/integration/60
t/integration/75
t/tools/3
t/tools/30
t/tools/33
t/tools/34
t/tools/36
t/tools/42
t/tools/43
t/tools/63
t/unit/auth/4
t/unit/auth/10
t/unit/data/24
t/unit/data/25
t/unit/data/62
t/unit/dav/9
t/unit/dav/10
t/unit/dav/11
t/unit/dav/12
t/unit/dav/24
t/unit/lib/5
t/unit/lib/8
t/unit/lib/19
t/unit/lib/20
t/unit/lib/26
t/unit/lib/41
t/unit/manager/8
t/unit/manager/9
t/unit/manager/10
t/unit/manager/11
t/unit/manager/13
t/unit/manager/34
t/unit/manager/35
t/unit/manager/50
t/unit/manager/51
t/unit/manager/61
t/unit/manager/62
t/unit/manager/63
t/unit/manager/64
t/unit/manager/65
t/unit/manager/66
t/unit/manager/67
t/unit/manager/76
t/unit/manager/77
t/unit/manager/78
t/unit/manager/80
t/unit/manager/98
t/unit/manager/99
t/unit/manager/100
t/unit/manager/101
t/unit/manager/103
t/unit/manager/104
t/unit/manager/105
t/unit/manager/106
t/unit/manager/107
t/unit/manager/108
t/unit/manager/109
t/unit/manager/110
t/unit/manager/111
t/unit/manager/140
t/unit/manager/141
t/unit/manager/142
t/unit/manager/156
t/unit/manager/157
t/unit/manager/158
t/unit/manager/159
t/unit/manager/160
t/unit/manager/165
t/unit/manager/166
t/unit/manager/175
t/unit/manager/191
t/unit/mcp/2
t/unit/mcp/12
t/unit/mcp/16
t/unit/mcp/17
t/unit/plugins/1
t/unit/plugins/5
t/unit/plugins/41
t/unit/processor/17
t/unit/processor/18
t/unit/processor/47
t/unit/users/14
t/unit/users/22
t/unit/users/31
t/unit/users/32
t/unit/users/33
t/unit/users/34
t/unit/users/35
t/unit/users/44
