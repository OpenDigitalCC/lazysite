#!/usr/bin/perl
# SM542: --scan (the manager Stats page refresh) persisted and finalised a
# closed day WITHOUT its form outcomes - only --export folded form-events in -
# so a day first seen by the page refresh was written with forms:{} and marked
# final, and the later --export never rewrote it. The durable record a day got
# depended on which entry point reached it first.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(decode_json);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use POSIX      qw(strftime mktime);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $PLUGIN = repo_root() . '/plugins/stats.pl';
ok( -f $PLUGIN, 'stats plugin present' );

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/$_") for qw(logs cache stats/form-events);
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_url: https://demo.example.io\n";
close $cf;

# Yesterday at local noon, so the date is the same in every timezone the
# plugin or this test might read it in.
my @y   = localtime( time - 86400 );
my $ts  = mktime( 0, 0, 12, $y[3], $y[4], $y[5] );
my $ymd = strftime( '%Y%m%d',   localtime $ts );
my $day = strftime( '%Y-%m-%d', localtime $ts );

open my $lf, '>', "$d/lazysite/logs/access-$ymd.jsonl" or die $!;
print {$lf}
    qq({"t":$ts,"p":"/contact","s":200,"ch":"page","v":"abcdef123456","ua":"Mozilla/5.0 Chrome/120"}\n);
close $lf;
open my $ff, '>', "$d/lazysite/stats/form-events/$day.jsonl" or die $!;
print {$ff} qq({"day":"$day","form":"contact","outcome":"stored"}\n);
print {$ff} qq({"day":"$day","form":"contact","outcome":"blocked","reason":"honeypot"}\n);
close $ff;

sub run {
    my (@args) = @_;
    my $out = qx($^X \Q$PLUGIN\E @args --docroot \Q$d\E 2>/dev/null);
    return decode_json( $out || '{}' );
}

sub day_file {
    open my $fh, '<', "$d/lazysite/stats/daily/$day.json" or return {};
    local $/;
    return decode_json(<$fh>);
}

my $scan = run('--scan');
ok( $scan->{ok}, 'the page refresh ran' ) or diag explain $scan;
my $after_scan = day_file();
is( $after_scan->{classes}{human} // 0, 1, 'the page refresh wrote the day file' );
is( $after_scan->{forms}{contact}{stored} // 0, 1,
    'and the day file carries the stored submission' )
    or diag explain $after_scan->{forms};
is( $after_scan->{forms}{contact}{blocked}{honeypot} // 0, 1, 'and the blocked one' );

my $export = run('--export');
ok( $export->{form_delivery}, 'the export reports the form outcomes' );
my $after_export = day_file();
is( $after_export->{forms}{contact}{stored} // 0, 1,
    'the day file still carries the outcome after the export' );
my $cache = decode_json( do { local $/; open my $c, '<', "$d/lazysite/cache/stats-export.json" or die $!; <$c> } );
ok( $cache->{final}{$day}, 'the closed day is final - and was final with its outcomes in' );

done_testing();
