#!/usr/bin/perl
# SM584: a check reported 'ok' where the vocabulary is 'OK'. The icon map
# had no such key, so the status label printed empty and perl warned - and
# the summary, which counts `eq 'OK'`, silently omitted the result from the
# tally AND from the exit code. A mis-levelled check is a check whose answer
# nobody reads, which is the defect class this project keeps removing.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $tool = repo_root() . '/tools/lazysite-check.pl';
open my $fh, '<', $tool or die "$tool: $!";
my $src = do { local $/; <$fh> };
close $fh;

subtest 'every report() call uses the uppercase vocabulary' => sub {
    my @bad = $src =~ /report\(\s*'((?!OK\b|WARN\b|FAIL\b)[A-Za-z]+)'/g;
    is_deeply( [ sort keys %{ { map { $_ => 1 } @bad } } ], [],
        'no call site passes a level outside OK/WARN/FAIL' )
        or diag( "levels found: @bad - the summary counts eq 'OK', so any "
            . 'other spelling is dropped from the tally and the exit code' );
};

subtest 'report() refuses an unknown level rather than passing it through' => sub {
    like( $src, qr/die "report: unknown level/,
        'the guard is present' );
    like( $src, qr/\$level =~ .*OK\|WARN\|FAIL/,
        'and it names the closed vocabulary' );
};

done_testing();
