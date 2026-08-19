#!/usr/bin/perl
# SM389: the security register recorded round 1 only, for a month.
#
# Two further review rounds had happened - the private 2026-07-21 report fixed
# in 0.9.9, and the four-reviewer SM268 round fixed in 0.10.5 - and neither was
# in the register. Every area still read `last_covered: round-1`, so the file
# said the last time anybody looked at path confinement was July, when in fact
# two later rounds had both looked at it. A coverage register that lags is worse
# than none: its whole purpose is to tell the NEXT round where to go, and a stale
# one sends it back over ground already walked while the gaps stay open.
#
# THIS TEST CANNOT KNOW WHETHER A ROUND HAPPENED. Nothing can - that is a fact
# about the world. What it can do is keep the file INTERNALLY honest, so the
# register never again claims coverage it cannot derive from its own rounds:
#
#   every area an area references is declared
#   every last_covered names a round that exists, and is the LATEST round
#     covering that area - a hand-edited value cannot drift from the rounds
#   never_covered is exactly the set no round claims - it cannot be padded to
#     look smaller or forgotten and left to look larger
#   the rounds are in date order and each names what fixed it
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $path = repo_root() . '/security/audit-register.json';
ok( -f $path, 'the security register is present' ) or BAIL_OUT('no register');

my $raw = do { open my $fh, '<', $path or die $!; local $/; <$fh> };
my $reg = eval { decode_json($raw) };
ok( $reg, 'it is valid JSON' ) or BAIL_OUT("unparseable: $@");

my @areas  = @{ $reg->{areas}  || [] };
my @rounds = @{ $reg->{rounds} || [] };
ok( @areas, 'it declares areas' );
cmp_ok( scalar @rounds, '>=', 3, 'it records every round that has happened' );

my %area_id  = map { $_->{id} => 1 } @areas;
my %round_id = map { $_->{id} => 1 } @rounds;

# Rounds in date order, each naming its target and the release that fixed it.
my $prev = '';
for my $r (@rounds) {
    ok( $r->{date} =~ /^\d{4}-\d{2}-\d{2}$/, "$r->{id} has a date" );
    ok( $r->{date} ge $prev,                 "$r->{id} follows the round before it" );
    $prev = $r->{date};
    ok( length( $r->{target}            // '' ), "$r->{id} names what it reviewed" );
    ok( length( $r->{fixes_released_in} // '' ), "$r->{id} names the release that fixed it" );

    for my $a ( @{ $r->{areas_covered} || [] } ) {
        ok( $area_id{$a}, "$r->{id} covers a declared area ($a)" );
    }
}

# last_covered must be DERIVED, not typed. Recompute it and compare - this is
# the assertion that catches a register left behind by a round.
my %latest;
for my $r (@rounds) {
    $latest{$_} = $r->{id} for @{ $r->{areas_covered} || [] };
}
for my $a (@areas) {
    is( $a->{last_covered}, $latest{ $a->{id} },
        "$a->{id} last_covered matches the rounds themselves" );
}

# never_covered is the complement, exactly.
my @never   = sort grep { !$latest{$_} } keys %area_id;
my @claimed = sort @{ ( $reg->{never_covered} || {} )->{areas} || [] };
is_deeply( \@claimed, \@never,
    'never_covered is exactly the areas no round claims - neither padded nor stale' );

ok( length( ( $reg->{never_covered} || {} )->{note} // '' ),
    'and it says why those gaps matter rather than listing them bare' );

done_testing();
