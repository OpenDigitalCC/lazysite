#!/usr/bin/perl
# SM606: an unknown query parameter is named, not silently dropped.
#
# The data endpoint assembles its binding from order_by, order, limit and offset
# and reads nothing else, so `?table=t&chunk=AAA` returned EVERY ROW - in a
# reply shaped exactly like a filtered one. A bad VALUE is a 400; an unknown
# PARAMETER was silence, and a caller could not tell the two apart. The site
# agent had written it up as a hazard to work around, which is the right
# instinct and the wrong resting place.
#
# REFUSING would have been the obvious fix and is the wrong one: any caller
# passing a harmless extra - a cache-buster is the ordinary case - would break,
# and that is a behaviour change deserving its own decision rather than arriving
# inside a defect fix. So the reply NAMES what it ignored: nobody breaks, and
# the silence is gone, which was the whole complaint.
use strict;
use warnings;
use Test::More;
use FindBin;

my $src = do {
    open my $fh, '<', "$FindBin::Bin/../../../lazysite-data.pl" or die $!;
    local $/; <$fh>;
};

# --- 1. the read set is declared, not inferred ------------------------------
# Whitespace-tolerant: perltidy aligns the `=` and the `map` block, and an
# assertion pinned to one spacing fails on a reformat that changed nothing.
my ($reads) = $src =~ /my %READS\s*=\s*map\s*\{[^}]*\}\s*qw\((.*?)\)/s;
ok( $reads, 'the endpoint declares which parameters it reads' );
my %declared = map { $_ => 1 } split ' ', ( $reads // '' );

# Every parameter the code actually consults must be in that list, or the
# endpoint would report a real parameter as ignored - which is worse than the
# silence it replaces, because it would be a confident wrong answer.
my %used = map { $_ => 1 } ( $src =~ /\$q\{([a-z_]+)\}/g );
for my $k ( sort keys %used ) {
    ok( $declared{$k}, "'$k' is consulted and is declared as read" );
}

# And the loop-read ones, which do not appear as literal $q{name}.
for my $k (qw(limit offset)) {
    ok( $declared{$k}, "'$k' - read through the qw() loop - is declared too" );
}

# --- 2. the reply carries both forms ----------------------------------------
{
    like( $src, qr/\@ignored \? \( ignored => \\\@ignored \)/,
        'the reply carries a machine-readable `ignored` list' );
    like( $src, qr/ignored parameter/,
        'and a human-readable warning' );
    like( $src, qr/\@\{ \$r->\{warnings\} \|\| \[\] \}/,
        'appended to the EXISTING warnings channel, so a client that already '
            . 'surfaces warnings shows this one without being changed' );
}

# --- 3. it does not refuse ---------------------------------------------------
# The decision this filing turned on. A 400 here would break every caller
# passing a cache-buster.
{
    like( $src, qr/my \@ignored = sort grep/, 'the ignored list is computed' );

    # Asserted on the SHAPE OF THE WRONG BEHAVIOUR, not on a region. The first
    # version extracted a block ending at the @ignored line and checked it held
    # no 400 - and a sabotage adding `return reply(400 ...) if @ignored;` on the
    # NEXT line passed, because it landed outside the extract. There are
    # legitimate 400s further down (a bad binding is one), so the region cannot
    # simply be widened: what must not exist is a refusal CONDITIONED ON
    # @ignored, and that is one line to look for.
    my @refusals = grep { /reply\(\s*400/ && /\@ignored/ } split /\n/, $src;
    is_deeply( \@refusals, [],
        'no refusal is conditioned on an unknown parameter - naming it is the '
            . 'whole point, and a 400 would break every caller passing a '
            . 'cache-buster' )
        or diag( join "\n", @refusals );
}

# --- 4. an empty ignored list adds nothing ----------------------------------
# The ordinary call must not grow a field. A reply that always carries
# `ignored: []` trains a reader to skip it.
{
    like( $src, qr/\( \@ignored \? \( ignored/,
        'the field appears only when something was actually ignored' );
}

done_testing();
