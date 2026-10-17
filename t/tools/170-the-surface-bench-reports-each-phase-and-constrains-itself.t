#!/usr/bin/perl
# SM1144 (SM1082 T0): tools/bench-surfaces.sh gives the before-figures SM1082 asked
# for, and does it without adding load to a shared host.
#
# The release manager's standing rule (2026-10-17) is that a measurement is never
# a load generator: it is pinned to one CPU at the lowest priority, sequential, and
# small by default. What is asserted here is the BEHAVIOUR that makes that true -
# it refuses to run unpinned, it refuses to run bare, it makes its requests one
# after another - and that its report has what the plan reads: a median and a 90th
# percentile for every phase of every surface, for the whole request, and for what
# no phase accounts for. N=2 against a throwaway site, so it is quick enough to be
# a test; the figures themselves are not asserted, only that they are there.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $sh   = "$root/tools/bench-surfaces.sh";
my $pl   = "$root/tools/bench-surfaces.pl";

plan skip_all => 'taskset is not installed on this host' unless grep { -x "$_/taskset" } split /:/, $ENV{PATH};

ok( -x $sh, 'tools/bench-surfaces.sh is executable' );

sub run {
    my ( $cmd, %env ) = @_;
    local %ENV = ( %ENV, %env );
    delete $ENV{BENCH_SURFACES_CONSTRAINED} unless exists $env{BENCH_SURFACES_CONSTRAINED};
    my $out = `$cmd 2>&1`;
    return ( $? >> 8, $out );
}

# --- it refuses to measure loose ----------------------------------------------------
{
    my ( $rc, $out ) = run("$^X $pl --n 1");
    isnt( $rc, 0, 'the worker run bare is refused' );
    like( $out, qr/tools\/bench-surfaces\.sh.*pins it to one CPU/s, '...and says to run it through the wrapper' );
}
{
    # A PATH holding nothing but the shell's own directory has no taskset.
    my ( $rc, $out ) = run( "/bin/bash $sh --n 1", PATH => '/nonexistent' );
    is( $rc, 2, 'a host that cannot pin is refused, not measured unpinned' );
    like( $out, qr/taskset is not installed/, '...with the reason' );
}

my $src = do { local $/; open my $fh, '<', $sh or die $!; <$fh> };
like( $src, qr/taskset -c "\$cpu" nice -n 19/, 'the wrapper pins to one CPU at nice 19' );

# --- the report -----------------------------------------------------------------------
my ( $rc, $out ) = run("/bin/bash $sh --n 2 --json");
is( $rc, 0, 'a run with N=2 against its throwaway site succeeds' ) or diag($out);
my ($json) = $out =~ /(\{.*\})\s*\z/s;
my $r = eval { decode_json( $json // '' ) } || {};
is( $r->{n}, 2, 'it says how many requests each figure is from' );

my %by = map { $_->{surface} . '/' . $_->{path} => $_ } @{ $r->{surfaces} || [] };
for my $s (qw(page page-signed-in manager mcp odoo odoo-direct dav)) {
    ok( $by{"$s/cgi"}, "$s was measured through the CGI" );
}
ok( $by{'data/cgi'} || ( grep { /^data / } @{ $r->{skipped} || [] } ), 'data was measured, or skipped with a reason' );
is( scalar( grep { $_->{path} ne 'cgi' } @{ $r->{surfaces} || [] } ), 0, 'with no pool asked for, there is no pool path' );

for my $k ( sort keys %by ) {
    my $p = $by{$k}{phases};
    ok( $p->{total} && defined $p->{total}{median} && defined $p->{total}{p90}, "$k: a median and a p90 for the whole request" );
    ok( $p->{config} && $p->{render}, "$k: it has config and render phases" ) or diag( join ',', sort keys %$p );
    ok( $p->{other} && defined $p->{other}{median}, "$k: and the time no phase accounts for" );
    cmp_ok( $p->{total}{p90}, '>=', $p->{total}{median}, "$k: p90 is not below the median" );
}
ok( $by{'page/cgi'}{phases}{load}, 'a CGI request has a load phase (a process per request)' );
ok( $by{'page-signed-in/cgi'}{phases}{identity}, 'a signed-in page has the wrapper\'s identity phase' );
is( $by{'mcp/cgi'}{status}, 200, 'the connector\'s call was authorised' );
is( $by{'dav/cgi'}{status}, 207, 'the WebDAV listing was answered' );

# --- the text form ------------------------------------------------------------------
( $rc, $out ) = run("/bin/bash $sh --n 2 --surface page,odoo-direct");
is( $rc, 0, 'the text form runs' );
like( $out, qr/^page\s+cgi\s+status 200 total [\d.]+\/[\d.]+\s+.*config [\d.]+\/[\d.]+/m, 'one line per surface, medians and p90s' );
like( $out, qr/one CPU, nice 19/, '...and says how it was constrained' );

done_testing;
