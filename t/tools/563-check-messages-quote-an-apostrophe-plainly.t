#!/usr/bin/perl
# n800: a check message quotes its apostrophe as an apostrophe. The engine-tree
# message read "front end`s deny rules"; no message string in the check or the
# CLI carries a backtick between two letters outside a comment.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

for my $f (qw(tools/lazysite-check.pl tools/lazysite-cli.pl)) {
    open my $fh, '<', "$root/$f" or die "$f: $!";
    my @bad;
    while ( my $l = <$fh> ) {
        next if $l =~ /^\s*#/;
        push @bad, "$.: $l" if $l =~ /[A-Za-z]`[a-z]/ && $l =~ /['"]/ && $l !~ /\bsystemctl\b|\bqx\b/;
    }
    is( scalar @bad, 0, "$f: no backtick stands for an apostrophe" ) or diag @bad;
}

done_testing();
