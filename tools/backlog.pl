#!/usr/bin/perl
# tools/backlog.pl - list the feature-request backlog from the status headers
# every docs/feature-requests/SM*.md carries (enforced by
# t/lint/09-feature-request-status.t).
#
#   perl tools/backlog.pl            # open work only (partial|parked|candidate)
#   perl tools/backlog.pl --all      # everything, shipped and superseded too
#
# Core-only Perl; no CPAN deps.
use strict;
use warnings;
use FindBin;

my $all  = grep { $_ eq '--all' } @ARGV;
my %OPEN = map  { $_ => 1 } qw(partial parked candidate);

my @rows;
for my $f ( sort glob "$FindBin::Bin/../docs/feature-requests/SM*.md" ) {
    open my $fh, '<', $f or next;
    my $text = do { local $/; <$fh> };
    close $fh;
    my ($fm) = $text =~ /\A---\n(.*?)^---\n/ms;
    next unless defined $fm;
    my ($id)     = $f  =~ /(SM\d{3}[a-z]?)[^\/]*$/;
    my ($status) = $fm =~ /^status:\s*(\S+)/m;
    my ($title)  = $fm =~ /^title:\s*"?(.*?)"?\s*$/m;
    my ($note)   = $fm =~ /^status-note:\s*"(.+)"\s*$/m;
    next unless defined $status;
    next unless $all || $OPEN{$status};
    $title =~ s/^SM\d{3}[a-z]?\s*[-:\x{2014}]\s*//u if defined $title;
    push @rows, [ $id, $status, $title // '', $note // '' ];
}

printf "%-7s %-10s %s\n", 'Id', 'Status', 'Item';
printf "%-7s %-10s %s\n", '--', '------', '----';
for my $r (@rows) {
    printf "%-7s %-10s %s\n", @{$r}[ 0, 1, 2 ];
    printf "%-18s %s\n", '', $r->[3] if length $r->[3];
}
print "\n", scalar @rows, ( $all ? " item(s) total.\n" : " open item(s).\n" );
