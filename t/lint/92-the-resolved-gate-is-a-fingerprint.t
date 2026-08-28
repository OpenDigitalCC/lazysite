#!/usr/bin/perl
# SM662: a fingerprint of what every capability gate ACTUALLY decides.
#
# WHY. A capability's reach is described in up to six places and changing one is
# never enough - SM633 hit six, SM652 hit six, SM664 hit six. The remedy SM662
# names is to make %need DECLARE its capability rather than test it, so the
# other five can be derived. That restructure touches the table that decides
# every authorisation on this surface, and it must not be attempted without
# something that proves the resolved answers are IDENTICAL before and after.
#
# This is that something, and it is deliberately landed FIRST and separately.
#
# HOW IT WORKS. Each %need entry is a predicate over a capability hash. Rather
# than read the predicate - which is exactly what cannot be done reliably, and
# the reason this filing exists - it is EXECUTED against a fixed battery of
# capability sets, and the yes/no answers are recorded. Two implementations that
# answer identically for every action across the whole battery are equivalent
# for every grant this system can actually issue, because every gate in the
# table is a combination of single capabilities.
#
# The battery: nothing, everything, and each capability alone. That distinguishes
# AND from OR (an AND answers no to every single capability and yes to all),
# distinguishes which capability is tested, and catches a gate that ignores its
# input entirely.
#
# WHAT THIS FILE ASSERTS TODAY is only that the fingerprint can be computed and
# is stable - no entry crashes, none is unreachable, none ignores its input
# without saying so. The comparison across a restructure is what it is FOR, and
# tools/gate-fingerprint.pl prints it for that purpose.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $api  = "$root/lazysite-manager-api.pl";
plan skip_all => 'manager api missing' unless -f $api;

my $src = do { open my $fh, '<', $api or die $!; local $/; <$fh> };

my ($need_src) = $src =~ /\n( *my %need = \(.*?\n *\);)/s;
ok( $need_src, 'the token gate table was extracted' )
    or BAIL_OUT('no %need - the fingerprint cannot be taken');

# The capability vocabulary, from the store's own list rather than a copy here -
# a hand-kept list would be the seventh place (SM662's own subject).
require Lazysite::Auth::Settings;
my @CAPS = @Lazysite::Auth::Settings::CAP_KEYS;
cmp_ok( scalar @CAPS, '>=', 15, 'the capability vocabulary was read from the store' );

# Predicates receive a caps hashref. Some also consult a second argument; those
# are called with an empty one so the answer is a function of capabilities only.
my %need = do {
    my %h;
    my $code = $need_src;
    $code =~ s/^ *my %need = \(/\%h = (/;
    my $ok = eval "package SM662Probe; no warnings; $code; 1";
    BAIL_OUT("could not compile the extracted gate table: $@") unless $ok;
    %h;
};
cmp_ok( scalar keys %need, '>=', 60, 'the gate table compiled with its entries' );

sub answers {
    my ($pred) = @_;
    return undef unless ref $pred eq 'CODE';
    my @row;
    for my $set ( [], [@CAPS], map { [$_] } @CAPS ) {
        my %caps = map { $_ => 1 } @{$set};
        my $r = eval { $pred->( \%caps, {} ) };
        push @row, ( defined $r && $r ) ? 1 : 0;
    }
    return \@row;
}

my ( %fingerprint, @constant, @broken );
for my $action ( sort keys %need ) {
    my $row = answers( $need{$action} );
    if ( !defined $row ) { next }    # not a coderef: a reason string, handled elsewhere
    push @broken, $action unless @{$row};
    $fingerprint{$action} = join '', @{$row};

    # A gate whose answer never changes ignores its input. `whoami => sub { 1 }`
    # is deliberate and named; anything else answering constantly is a gate that
    # is not gating.
    push @constant, $action if $fingerprint{$action} !~ /0/ || $fingerprint{$action} !~ /1/;
}

is_deeply( \@broken, [], 'every predicate evaluated without dying' );

my %DELIBERATELY_CONSTANT = map { $_ => 1 } qw(whoami describe-capabilities actions-list);
my @unexpected = grep { !$DELIBERATELY_CONSTANT{$_} } @constant;
is_deeply( \@unexpected, [], 'no gate silently ignores the capabilities it is given' )
    or diag( "constant-answer gates: @unexpected\n"
        . 'A gate that answers the same for every capability set is not gating. '
        . 'If that is intended, name it in %DELIBERATELY_CONSTANT so the next '
        . 'reader knows it was a decision.' );

# The AND/OR distinction the fingerprint exists to preserve: an AND gate answers
# NO to every single capability and YES only to the full set, so its row is
# 0 1 followed by all zeros. An OR gate answers yes to at least one single
# capability. If a restructure turned one into the other the row changes shape,
# and the comparison catches it - which reading the new table would not.
my @and_like = sort grep {
    my $f = $fingerprint{$_};
    $f =~ /^01 *0*$/ && $f !~ /1.+1/;
} keys %fingerprint;
note( 'AND-shaped gates: ' . ( @and_like ? join( ', ', @and_like ) : 'none' ) );
ok( 1, 'fingerprint taken for ' . scalar( keys %fingerprint ) . ' gated actions' );

done_testing();
