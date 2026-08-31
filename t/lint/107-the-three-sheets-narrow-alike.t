#!/usr/bin/perl
# MR-49: three sheets, one set of breakpoints.
#
# The manager ships classic, modern and accessible. They differ in ink, type
# and weight; they do NOT differ in what fits on a phone. A narrow-width rule
# added to one and forgotten in the other two is invisible to every check
# there is: each sheet parses, every class it names exists (t/lint/95), the
# style guide still agrees with it (t/lint/96), and the page looks right in
# whichever theme the person fixing it happened to be using.
#
# So this asserts PARITY, which a gate can check, rather than layout, which
# needs a browser: the same media queries, and the same selectors inside them.
#
# What it cannot see, said plainly so nobody mistakes a pass for a measurement:
# whether the header actually fits. That was measured with a real browser -
# documentElement.scrollWidth against clientWidth on sixteen pages at five
# widths - and the number that mattered was 737px of header in a 420px
# viewport, on every page in the manager.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root  = repo_root();
my $asset = "$root/starter/lazysite/manager/assets";
my @SHEETS = qw(manager-classic.css manager-modern.css manager-accessible.css);

my %rules;
for my $s (@SHEETS) {
    my $path = "$asset/$s";
    plan skip_all => "no $s" unless -f $path;
    my $css = do { open my $fh, '<', $path or die $!; local $/; <$fh> };

    # Width-based blocks only: a colour-scheme or reduced-motion query says
    # nothing about narrow widths, and the sheets legitimately differ there.
    while ( $css =~ /\@media\s*\(\s*(max|min)-width:\s*(\d+)px\s*\)\s*\{/g ) {
        my $q     = "$1-width: $2px";
        my $start = pos($css);
        my $depth = 1;
        my $i     = $start;
        while ( $depth && $i < length $css ) {
            my $c = substr $css, $i, 1;
            $depth++ if $c eq '{';
            $depth-- if $c eq '}';
            $i++;
        }
        my $body = substr $css, $start, $i - $start - 1;
        my @sel = $body =~ /(?:^|\}|\{)\s*([^{}\n][^{}]*?)\s*\{/g;
        s/\s+/ /g for @sel;
        $rules{$s}{$q} = [ sort @sel ];
    }
}

my ($first, @rest) = @SHEETS;

subtest 'every sheet narrows at the same widths' => sub {
    for my $s (@rest) {
        is_deeply( [ sort keys %{ $rules{$s} } ], [ sort keys %{ $rules{$first} } ],
            "$s has the same width breakpoints as $first" )
            or diag( 'A breakpoint in one sheet and not another means the '
                . 'manager reflows at a different width depending on which '
                . 'theme the reader chose - and whoever fixed it saw it fixed.' );
    }
};

subtest 'and each breakpoint carries the same rules' => sub {
    for my $q ( sort keys %{ $rules{$first} } ) {
        for my $s (@rest) {
            next unless $rules{$s}{$q};
            is_deeply( $rules{$s}{$q}, $rules{$first}{$q},
                "$s: \@media ($q) matches $first" )
                or diag( 'The selectors inside a width query are the layout '
                    . 'decision, not the styling. If one sheet drops the '
                    . 'account name at 560px and another keeps it, the header '
                    . 'overflows in one theme and not the other.' );
        }
    }
};

done_testing();
