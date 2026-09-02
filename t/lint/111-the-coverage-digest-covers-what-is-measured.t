#!/usr/bin/perl
# SM736: the digest that licenses skipping coverage must cover exactly what
# coverage measures.
#
# THE FAILURE THIS PREVENTS. tools/coverage-inputs.pl names the eight gated
# CGIs, and tools/coverage.sh names them again in its floor loop. If the two
# ever disagree, the digest attests a set that is not the measured set - and the
# skip would then be licensed by a hash of the wrong files. That is a silent
# wrong answer, which is the worst kind, so the two lists are compared here.
#
# The rest of the input set - t/ and lib/ - is enumerated by directory rather
# than by name and cannot drift the same way.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; <$fh> }

my $inputs = slurp("$root/tools/coverage-inputs.pl");
my $cover  = slurp("$root/tools/coverage.sh");

subtest 'both files name the same gated CGIs' => sub {
    my ($iblock) = $inputs =~ /my \@EXPLICIT = qw\(\s*(.*?)\s*\);/s;
    ok( $iblock, 'the digest tool declares its explicit list' ) or return;
    my %digested = map { $_ => 1 }
        grep { /\.pl$/ } split ' ', $iblock;

    my ($cblock) = $cover =~ /for f in ((?:[^\n]*\\\n)*[^\n]*); do/;
    ok( $cblock, 'coverage.sh declares its floor loop' ) or return;
    $cblock =~ s/\\\n/ /g;
    my %measured = map { $_ => 1 } grep { /\.pl$/ } split ' ', $cblock;

    my @missing = sort grep { !$digested{$_} } keys %measured;
    my @extra   = sort grep { !$measured{$_} } keys %digested;

    is( scalar @missing, 0,
        'every measured CGI is in the digest (a skip must not be licensed by a hash that omits one)' )
        or diag( "measured but not digested: @missing" );
    is( scalar @extra, 0, 'and the digest names nothing that is not measured' )
        or diag( "digested but not measured: @extra" );
    cmp_ok( scalar keys %measured, '>=', 8, 'the measured set is the expected size' );
};

subtest 'the skip can only be reached by a positive match' => sub {
    my ($block) = $cover =~ /(SM736: SKIP WHEN.*?^fi$)/ms;
    ok( $block, 'the skip block is present' ) or return;

    like( $block, qr/result.*?\}\s*\/\/\s*""\)\s*eq\s*"pass"/s,
        'a recorded FAILURE cannot license a skip' );
    like( $block, qr/\[ -f "\$COVER_RECORD" \]/,
        'a missing record cannot license a skip' );
    like( $block, qr/\[ "\$prev" = "\$COVER_DIGEST" \]/,
        'and the digests must be equal, not merely both present' );
    like( $block, qr/LAZYSITE_COVER_FORCE/,
        'and there is a way to override it' );
};

subtest 'a pass is recorded only after the floors are met' => sub {
    # The record is written inside the success branch, after the floor loop -
    # so a run that fell below the floor cannot leave a record that would let
    # the next run skip.
    my $fail_exit = index( $cover, 'COVERAGE BELOW FLOOR' );
    my $record    = index( $cover, '"result": "pass"' );
    cmp_ok( $fail_exit, '>', -1, 'the below-floor exit exists' );
    cmp_ok( $record,    '>', -1, 'the record is written' );
    cmp_ok( $fail_exit, '<', $record,
        'the below-floor exit comes FIRST, so a failing run never records a pass' );
};

done_testing();
