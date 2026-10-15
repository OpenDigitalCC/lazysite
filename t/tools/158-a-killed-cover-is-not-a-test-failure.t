#!/usr/bin/env perl
# SM1083: when `cover` is killed (exit 137/143) coverage.sh says
# "coverage: KILLED (memory/signal)" (exit 6), not a test failure and not a
# shortfall; release.sh names that verdict. A stub cover; no instrumented run.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd);

my $root = repo_root();
my $tmp  = tempdir( CLEANUP => 1 );
mkdir "$tmp/bin";
mkdir "$tmp/db";
for my $rc ( 143, 137, 1 ) {
    open my $f, '>', "$tmp/bin/cover" or die;
    print {$f} "#!/bin/sh\nexit $rc\n";
    close $f;
    chmod 0755, "$tmp/bin/cover";
    local $ENV{PATH}                       = "$tmp/bin:$ENV{PATH}";
    local $ENV{LAZYSITE_COVER_REPORT_ONLY} = 1;
    local $ENV{LAZYSITE_COVER_FORCE}       = 1;
    local $ENV{LAZYSITE_COVER_DB}          = "$tmp/db";
    local $ENV{LAZYSITE_COVER_SUITE_LOG}   = "$tmp/x-suite.txt";
    my $o = run_cmd( 'bash', "$root/tools/coverage.sh", '--check' );
    my $x = $? >> 8;
    if ( $rc == 1 ) {
        like( $o, qr/THE REPORT STEP FAILED/, 'an ordinary cover failure is still the report-step failure' );
        unlike( $o, qr/KILLED/, 'and is not called killed' );
    }
    else {
        like( $o, qr/^coverage: KILLED \(memory\/signal\) - cover exit $rc/m, "cover exit $rc is KILLED" ) or diag($o);
        like( $o, qr/not a test failure and not a shortfall/, 'said plainly' );
        is( $x, 6, 'exit 6' );
    }
}
my $rel = run_cmd( 'grep', '-c', 'verdict KILLED', "$root/tools/release.sh" );
is( $rel + 0, 1, 'release.sh reports the KILLED verdict' );
done_testing;
