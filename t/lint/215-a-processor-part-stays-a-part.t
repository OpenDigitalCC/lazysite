#!/usr/bin/perl
# SM944: THE PROCESSOR'S PARTS STAY PARTS.
#
# The processor is being split by area into files under lazysite-processor/ that
# it requires by absolute path from beside itself. That keeps ADR 0001's render
# path - no Lazysite:: module, no lib tree, no module load on a cache hit - only
# while every part keeps four promises, and each is one a later edit could break
# without any test noticing:
#
#   1. it is package main, so a move is a pure move and nothing is imported;
#   2. it loads nothing at compile time (strict and warnings only) - a `use`
#      here is a load on every request, which is the trade ADR 0001 refused;
#   3. the script's loader names exactly the files that exist, so a part is
#      never shipped unloaded nor loaded from somewhere it is not;
#   4. no sub is defined twice across the script and its parts, so a move
#      that left its original behind (one silently wins) fails here.
#
# And each starts with the index a reader needs first: HOLDS and OWNS lines.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $dir  = "$root/lazysite-processor";

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

opendir my $dh, $dir or die "$dir: $!";
my @parts = sort grep { !/^\./ && -f "$dir/$_" } readdir $dh;
closedir $dh;
ok( scalar @parts, 'the processor has parts' );

my $proc = slurp("$root/lazysite-processor.pl");

subtest 'the loader names exactly the parts that exist, by path' => sub {
    my ($list) = $proc =~ /for my \$part \(qw\(([^)]*)\)\)/;
    ok( defined $list, 'the loader is found' ) or return;
    is_deeply( [ sort split ' ', $list ], \@parts,
        'every part is loaded, and nothing is loaded that is not a part' );
    like( $proc, qr/dirname\(\s*realpath\(__FILE__\)\s*\)\s*\.\s*'\/lazysite-processor'/,
        'the parts are found from where the script really is, not through @INC' );
};

my %defined_in;
push @{ $defined_in{$_} }, 'lazysite-processor.pl' for $proc =~ /^sub (\w+)/mg;

for my $p (@parts) {
    subtest $p => sub {
        like( $p, qr/\A[a-z][a-z0-9-]*\.pm\z/,
            'a .pm, so the installer leaves it 0644 and no web server runs it' );
        my $s = slurp("$dir/$p");
        like( $s, qr/\Apackage main;\n/, 'package main, first line' );
        like( $s, qr/^# HOLDS /m, 'the index says what it holds' );
        like( $s, qr/^# OWNS /m,  'the index says what it owns' );
        my @use = grep { $_ ne 'strict' && $_ ne 'warnings' } $s =~ /^\s*use\s+([\w:]+)/mg;
        is_deeply( \@use, [], 'loads nothing at compile time (ADR 0001)' );
        ( my $code = $s ) =~ s/^\s*#.*\n//mg;
        unlike( $code, qr/\@INC/, 'touches no @INC' );
        push @{ $defined_in{$_} }, $p for $s =~ /^sub (\w+)/mg;
    };
}

my @twice = sort grep { @{ $defined_in{$_} } > 1 } keys %defined_in;
is_deeply( \@twice, [], 'no sub is defined in two places' )
    or diag( join "\n", map { "  $_: @{ $defined_in{$_} }" } @twice );

done_testing();
