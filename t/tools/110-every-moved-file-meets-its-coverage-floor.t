#!/usr/bin/perl
# P19 (WORK-PLAN-0154, ruled 2026-10-12): the coverage gate holds every file the
# CGIs were split into - each lazysite-processor/*.pm part and each
# lib/Lazysite/Manager/*.pm module - to a floor of its own, not only the CGIs.
#
# Driven for real: tools/coverage.sh --check, copied into a scratch tree with
# the floor file, a handful of parts and modules, and a `cover` on PATH that
# prints a canned report (REPORT_ONLY, so no instrumented suite is run). What is
# asserted is the verdict: a part below the floor fails the gate by name, a part
# the report does not measure fails it, a named override holds the files that
# measured low, and branch_floor[FILE] is never read as floor[FILE].
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Copy qw(copy);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $root = repo_root();
plan skip_all => 'awk and flock are needed' unless -x '/usr/bin/awk' && -x '/usr/bin/flock';

my $t = site_tempdir();
make_path( "$t/tools", "$t/dist/config", "$t/lazysite-processor", "$t/lib/Lazysite/Manager", "$t/bin", "$t/cover_db" );
copy( "$root/tools/$_", "$t/tools/$_" ) or die "$_: $!" for qw(coverage.sh coverage-inputs.pl);
copy( "$root/dist/config/coverage-floor", "$t/dist/config/coverage-floor" ) or die $!;
sub spit { my ( $p, $s ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $s; close $fh; return }
spit( "$t/$_", "1;\n" )
    for qw(lazysite-processor/render.pm lazysite-processor/oembed.pm lib/Lazysite/Manager/Config.pm
    lib/Lazysite/Manager/Nav.pm);
spit( "$t/bin/cover", "#!/bin/sh\ncat \"\$FAKE_COVER_REPORT\"\n" );
chmod 0755, "$t/bin/cover";

my @CGIS = qw(lazysite-dav.pl lazysite-processor.pl lazysite-manager-api.pl lazysite-auth.pl
    lazysite-mcp.pl lazysite-oauth.pl tools/lazysite-users.pl tools/lazysite-bundle-apply.pl);

sub check {
    my (%row) = @_;
    my %all = ( ( map { $_ => [ 90, 80 ] } @CGIS ),
        'lazysite-processor/render.pm'   => [ 97, 90 ],
        'lazysite-processor/oembed.pm'   => [ 35, 1 ],
        'lib/Lazysite/Manager/Config.pm' => [ 87, 61 ],
        'lib/Lazysite/Manager/Nav.pm'    => [ 96, 76 ],
        %row );
    my $report = "File stmt bran cond sub pod time total\n";
    for my $f ( sort keys %all ) {
        next unless defined $all{$f};
        $report .= sprintf "%-40s %5.1f %5.1f 50.0 90.0 0.0 1.0 80.0\n", $f, @{ $all{$f} };
    }
    spit( "$t/report.txt", $report );
    local %ENV = %ENV;
    $ENV{PATH}                       = "$t/bin:$ENV{PATH}";
    $ENV{FAKE_COVER_REPORT}          = "$t/report.txt";
    $ENV{LAZYSITE_COVER_REPORT_ONLY} = '1';
    $ENV{LAZYSITE_COVER_RECORD}      = "$t/no-record.json";
    $ENV{LAZYSITE_COVER_SUITE_LOG}   = "$t/suite.log";
    my $out = qx(sh \Q$t/tools/coverage.sh\E --check 2>&1);
    return ( $? >> 8, $out );
}

subtest 'the parts and modules are gated, each by name' => sub {
    my ( $rc, $out ) = check();
    is( $rc, 0, 'every file at or above its floor: the gate passes' ) or diag $out;
    like( $out, qr{lazysite-processor/render\.pm\s+stmt\s+97%.*\bok\b}, 'a processor part is checked' );
    like( $out, qr{lib/Lazysite/Manager/Nav\.pm\s+stmt\s+96%.*\bok\b}, 'a manager module is checked' );
};

subtest 'a part below the floor fails the gate, named' => sub {
    my ( $rc, $out ) = check( 'lazysite-processor/render.pm' => [ 60, 90 ] );
    is( $rc, 1, 'the gate fails' );
    like( $out, qr{lazysite-processor/render\.pm\s+stmt\s+60%.*BELOW}, 'naming the part' );
    like( $out, qr/COVERAGE BELOW FLOOR/, 'with the marker the release gate keys on' );
    ( $rc, $out ) = check( 'lib/Lazysite/Manager/Nav.pm' => [ 96, 50 ] );
    like( $out, qr{Manager/Nav\.pm.*BELOW-BRANCH}, 'a module\'s branches too' );
};

subtest 'a part the report does not measure fails the gate' => sub {
    my ( $rc, $out ) = check( 'lib/Lazysite/Manager/Nav.pm' => undef );
    is( $rc, 1, 'the gate fails' );
    like( $out, qr{lib/Lazysite/Manager/Nav\.pm\s+NOT MEASURED}, 'saying which file was not measured' );
};

subtest 'a named floor holds a file that measured low, and no lower' => sub {
    my ( $rc, $out ) = check();
    like( $out, qr{oembed\.pm\s+stmt\s+35%.*\(floors 34%/0%\)\s+ok}, 'oembed.pm at its own floors' );
    ( $rc, $out ) = check( 'lazysite-processor/oembed.pm' => [ 30, 1 ] );
    like( $out, qr{oembed\.pm.*BELOW}, 'and below them it fails' );
};

subtest 'branch_floor[FILE] is not read as floor[FILE]' => sub {
    my ( $rc, $out ) = check( 'lib/Lazysite/Manager/Config.pm' => [ 70, 61 ] );
    like( $out, qr{Manager/Config\.pm\s+stmt\s+70%.*\(floors 75%/60%\)\s+BELOW},
        'Config.pm\'s branch override (60) leaves its statement floor at 75' );
};

done_testing();
