#!/usr/bin/perl
# The control-API action registry is a hash literal: a key declared twice is
# silently collapsed - the second wins, no warning from perl, and an edit to
# the other line is discarded without a trace. Found live by the site agent:
# 'data-table-save' declared twice, byte-identical - harmless right up until
# someone edits one of them and the registry keeps the other.
use strict;
use warnings;
use Test::More;
use FindBin;

my $file = "$FindBin::Bin/../../lib/Lazysite/ControlApi/Actions.pm";
open my $fh, '<', $file or die "$file: $!";
my %seen;
while ( my $l = <$fh> ) {
    next unless $l =~ /^\s*'([a-z0-9-]+)'\s*=>\s*\{/;
    push @{ $seen{$1} }, $.;
}
close $fh;

my @dup = sort grep { @{ $seen{$_} } > 1 } keys %seen;
is_deeply( \@dup, [], 'every action key is declared exactly once' )
    or diag( join "\n", map { "$_: lines @{ $seen{$_} }" } @dup );

cmp_ok( scalar keys %seen, '>', 50, 'the scan actually saw the registry' );

done_testing();
