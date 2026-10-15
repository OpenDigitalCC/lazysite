#!/usr/bin/env perl
# SM1083 coverage in parts: a group still marked pre-rebaseline reports a file
# under its starting floor as MOVEMENT and passes; the same numbers against a
# baselined floor file are BELOW and fail. The real coverage.sh, in group mode,
# re-reporting a DB through a stub `cover` - no suite is run.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd);

my $root = repo_root();

sub spit {
    my ( $p, $t ) = @_;
    ( my $dir = $p ) =~ s{/[^/]+$}{};
    make_path($dir);
    open my $f, '>', $p or die "$p: $!";
    print {$f} $t;
    close $f;
}

# cover(1) stand-in: a text report with the processor CGI at 50% / 40%.
my $COVER = "#!/bin/sh\nprintf 'File  stmt  bran  cond  sub  total\\n/x/lazysite-processor.pl 50.0 40.0 n/a 90.0 60.0\\nTotal 50.0 40.0 n/a 90.0 60.0\\n'\n";

sub verdict {
    my ( $floor_lines, $files ) = @_;
    $files //= "lazysite-processor.pl\n";
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/tools", "$d/bin", "$d/db", "$d/t" );
    copy( "$root/tools/$_", "$d/tools/$_" ) or die "$_: $!" for qw(coverage.sh heavy-lock.sh preflight.sh);
    spit( "$d/bin/cover", $COVER );
    chmod 0755, "$d/bin/cover";
    spit( "$d/lazysite-processor.pl", "print 1;\n" );
    spit( "$d/floor",                 $floor_lines );
    spit( "$d/files",                 $files );
    local $ENV{PATH}                       = "$d/bin:$ENV{PATH}";
    local $ENV{PERL5OPT}                   = '';
    local $ENV{LAZYSITE_COVER_GROUP}       = 'processor';
    local $ENV{LAZYSITE_COVER_FILES}       = "$d/files";
    local $ENV{LAZYSITE_COVER_FLOOR_FILE}  = "$d/floor";
    local $ENV{LAZYSITE_COVER_DB}          = "$d/db";
    local $ENV{LAZYSITE_COVER_REPORT_ONLY} = 1;
    local $ENV{LAZYSITE_COVER_SUITE_LOG}   = "$d/suite.log";
    local $ENV{LAZYSITE_HEAVY_HELD}        = 1;
    my $o = run_cmd( 'bash', "$d/tools/coverage.sh", '--check' );
    return ( $? >> 8, $o );
}

my ( $rc, $o ) = verdict("floor=75\nbranch_floor=62\nstatus=pre-rebaseline\n");
is( $rc, 0, 'pre-rebaseline: a file under its starting floor does not fail' ) or diag($o);
like( $o, qr/lazysite-processor\.pl\s+stmt\s+50%\s+bran\s+40\.0%\s+\(floors 75%\/62%\)\s+MOVEMENT \(pre-rebaseline, was BELOW-BRANCH\)/, 'the row says MOVEMENT, and what it would have been' );
like( $o, qr/^coverage: PRE-REBASELINE - moved against the starting floors, recorded, not failed: lazysite-processor\.pl stmt 50% bran 40\.0% vs 75%\/62%; $/m, 'the movement is said in one line' );
unlike( $o, qr/COVERAGE BELOW FLOOR/, 'and is not a shortfall' );

( $rc, $o ) = verdict("floor=75\nbranch_floor=62\n");
is( $rc, 1, 'baselined: the same numbers fail' );
like( $o, qr/COVERAGE BELOW FLOOR/, 'as a shortfall' );
like( $o, qr/lazysite-processor\.pl\s+stmt\s+50%.*BELOW-BRANCH$/m, 'the row says BELOW-BRANCH (the branch floor is the one missed last)' );
unlike( $o, qr/MOVEMENT|PRE-REBASELINE/, 'and nothing says movement' );

( $rc, $o ) = verdict("floor=40\nbranch_floor=30\nstatus=pre-rebaseline\n");
is( $rc, 0, 'pre-rebaseline with the floors met passes' );
unlike( $o, qr/MOVEMENT|PRE-REBASELINE/, 'and reports no movement' );

# 0.15.5: the tools group's tests never ran its gated file, and NOT MEASURED
# failed the gate regardless of the status. Under pre-rebaseline that is a
# measure too.
my $two = "lazysite-processor.pl\nlazysite-manager-api.pl\n";
( $rc, $o ) = verdict( "floor=40\nbranch_floor=30\nstatus=pre-rebaseline\n", $two );
is( $rc, 0, 'pre-rebaseline: a gated file the group\'s tests do not reach does not fail' ) or diag($o);
like( $o, qr/^\s+lazysite-manager-api\.pl\s+NOT MEASURED by this group's tests  MOVEMENT \(pre-rebaseline, was gate failure\)$/m, 'the row says so' );
like( $o, qr/^coverage: PRE-REBASELINE - .*: lazysite-manager-api\.pl not measured by this group's tests; $/m, 'and the movement line carries it' );
( $rc, $o ) = verdict( "floor=75\nbranch_floor=62\nstatus=pre-rebaseline\n", $two );
is( $rc, 0, 'pre-rebaseline: one file below and one unreached both pass as movement' ) or diag($o);
like( $o, qr/lazysite-processor\.pl stmt 50% bran 40\.0% vs 75%\/62%; lazysite-manager-api\.pl not measured by this group's tests; /, 'both carried' );
( $rc, $o ) = verdict( "floor=40\nbranch_floor=30\n", $two );
is( $rc, 1, 'baselined: the same is a gate failure' );
like( $o, qr/lazysite-manager-api\.pl\s+NOT MEASURED - gate failure/, 'as before' );

subtest 'a pre-rebaseline group records its measure (a real miniature run)' => sub {
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/tools", "$d/bin", "$d/t/unit/processor" );
    copy( "$root/tools/$_", "$d/tools/$_" ) or die "$_: $!" for qw(coverage.sh heavy-lock.sh preflight.sh coverage-groups.pl precheck-areas.pl);
    spit( "$d/bin/cover", $COVER );
    chmod 0755, "$d/bin/cover";
    spit( "$d/lazysite-processor.pl",   "print 1;\n" );
    spit( "$d/t/unit/processor/01-a.t", "use Test::More tests => 1; ok 1;\n" );
    spit( "$d/tests",                   "t/unit/processor/01-a.t\n" );
    spit( "$d/files",                   "lazysite-processor.pl\n" );
    spit( "$d/floor", "floor=75\nbranch_floor=62\nstatus=pre-rebaseline\n" );
    spit( "$d/dist/config/coverage-floor", "floor=75\nbranch_floor=62\n" );
    local $ENV{PATH}                      = "$d/bin:$ENV{PATH}";
    local $ENV{PERL5OPT}                  = '';
    local $ENV{LAZYSITE_COVER_GROUP}      = 'processor';
    local $ENV{LAZYSITE_COVER_TESTS}      = "$d/tests";
    local $ENV{LAZYSITE_COVER_FILES}      = "$d/files";
    local $ENV{LAZYSITE_COVER_FLOOR_FILE} = "$d/floor";
    local $ENV{LAZYSITE_COVER_DB}         = "$d/cover_db";
    local $ENV{LAZYSITE_COVER_RECORD}     = "$d/record.json";
    local $ENV{LAZYSITE_COVER_SUITE_LOG}  = "$d/suite.log";
    local $ENV{LAZYSITE_COVER_FORCE}      = 1;
    local $ENV{LAZYSITE_COVER_JOBS}       = 1;
    local $ENV{LAZYSITE_HEAVY_HELD}       = 1;
    delete local $ENV{LAZYSITE_COVER_REPORT_ONLY};
    my $o  = run_cmd( 'bash', "$d/tools/coverage.sh", '--check' );
    my $rc = $? >> 8;
    is( $rc, 0, 'the group passes' ) or diag($o);
    like( $o, qr/^coverage: PRE-REBASELINE - moved against the starting floors, recorded, not failed: lazysite-processor\.pl stmt 50% bran 40\.0% vs 75%\/62%; $/m, 'saying what moved' );
    my $rec = do { local $/; open my $fh, '<', "$d/record.json" or ''; <$fh> } // '';
    like( $rec, qr/"result": "pass"/,           'the pass is recorded' );
    like( $rec, qr/"status": "pre-rebaseline"/, 'as pre-rebaseline' );
    like( $rec, qr/"movement": "lazysite-processor\.pl stmt 50% bran 40\.0% vs 75%\/62%; "/, 'with the measured figure for the re-baseline commit' );
    like( $rec, qr/"inputs_digest": "[0-9a-f]{64}"/, 'under the group\'s digest' );
};
done_testing;
