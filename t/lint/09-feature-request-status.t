#!/usr/bin/perl
# H-2 guarantee: every feature-request doc carries a machine-readable status
# header, so the backlog is mechanically listable (tools/backlog.pl) instead
# of inferred by cross-referencing the CHANGELOG. A new SM doc cannot land
# without declaring where it stands; the non-terminal states must say what
# remains or what replaced them.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my %ALLOWED    = map { $_ => 1 } qw(shipped partial parked candidate superseded);
my %NEEDS_NOTE = map { $_ => 1 } qw(partial superseded);

my @files = sort glob( repo_root() . '/docs/feature-requests/SM*.md' );
cmp_ok( scalar @files, '>=', 60, 'the feature-request corpus is present' );

for my $f (@files) {
    ( my $rel = $f ) =~ s{.*/docs/}{docs/};
    open my $fh, '<', $f or do { fail("$rel: unreadable"); next };
    my $text = do { local $/; <$fh> };
    close $fh;

    my ($fm) = $text =~ /\A---\n(.*?)^---\n/ms;
    ok( defined $fm, "$rel: has YAML front matter" ) or next;

    my ($status) = $fm =~ /^status:\s*(\S+)\s*$/m;
    ok( defined $status && $ALLOWED{$status},
        "$rel: status header present and one of [" . join( '|', sort keys %ALLOWED ) . ']' )
        or next;

    my ($note) = $fm =~ /^status-note:\s*"(.+)"\s*$/m;
    if ( $NEEDS_NOTE{$status} ) {
        ok( defined $note && length $note,
            "$rel: a '$status' item says what remains / what replaced it" );
    }
}

done_testing();
