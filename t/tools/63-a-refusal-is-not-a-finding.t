#!/usr/bin/perl
# SM562: a refusal is a refusal, a finding is a finding.
#
# run_tool_per_site labelled every non-zero child exit "with findings".
# lazysite-check.pl exits 1 for FAIL and 2 for could-not-check, so a site the
# tool could not look at - no engine tree, "Is this a lazysite docroot?" -
# was reported as a site finding, and an operator went looking for a content
# problem on a site whose real state was that nothing had looked at it. The
# Hestia rollout script (t/tools/42-rollout) already keeps the split at the
# shell layer; this pins it for the CLI.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $cli  = "$root/tools/lazysite-cli.pl";
plan skip_all => 'the CLI is missing' unless -f $cli;

# Two registered sites: one the check can examine (and will find fault with,
# as a bare fixture always does), one with no engine tree at all.
my $reg  = tempdir( CLEANUP => 1 );
my $base = tempdir( CLEANUP => 1 );
for my $n (qw(good.example plain.example)) {
    my $doc = "$base/$n/public_html";
    my $cgi = "$base/$n/cgi-bin";
    make_path( $doc, $cgi );
    if ( $n eq 'good.example' ) {
        make_path("$doc/lazysite/auth");
        open my $c, '>', "$doc/lazysite/lazysite.conf" or die $!;
        print $c "site_name: $n\n";
        close $c;
    }
    open my $r, '>', "$reg/$n" or die $!;
    print $r "docroot=$doc\ncgibin=$cgi\n";
    close $r;
}

local $ENV{LAZYSITE_REGISTRY_DIR} = $reg;
my $cmd = join ' ', map { "'$_'" } ( $^X, $cli, 'check', '--all' );
my $out = qx($cmd 2>&1);
my $rc  = $? >> 8;

like( $out, qr/no engine tree for .*plain\.example/,
    'the child refused the bare docroot as not a lazysite site' )
    or diag("output:\n$out");

like( $out, qr/^== \d+ ok, \d+ with findings, \d+ could not check\.$/m,
    'the summary has a third bucket for sites that could not be checked' )
    or diag("output:\n$out");

like( $out, qr/^\s+could not check: .*plain\.example/m,
    'the refused site is named under "could not check"' );

unlike( $out, qr/^\s+findings on: .*plain\.example/m,
    'and NOT under "findings on" - nobody looked, so nothing was found' )
    or diag( 'An operator reading "findings on: plain.example" goes hunting for '
        . 'a content problem on a site the tool never examined.' );

is( $rc, 2, 'the fleet still exits with the worst status (could-not-check is 2)' );

done_testing();
