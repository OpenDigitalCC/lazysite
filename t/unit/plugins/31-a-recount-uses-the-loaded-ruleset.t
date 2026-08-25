#!/usr/bin/perl
# SM543: --recount --apply must classify under the ruleset the operator loaded
# (lazysite/stats/classifiers.json, SM391), not the built-ins. The recount was
# dispatched before _compile_rules() ran and re-entered export_stats
# in-process, so the repair tool undid the operator's classification and
# reported changed=1 for the damage.
#
# (t/unit/plugins/11 pins the export path loading the ruleset; this pins the
# recount path.)
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(decode_json);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use POSIX      qw(strftime);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root run_cmd);

my $PLUGIN = repo_root() . '/plugins/stats.pl';
ok( -f $PLUGIN, 'stats plugin present' );

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/$_") for qw(logs cache stats);
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_url: https://demo.example.io\n";
close $cf;
open my $rf, '>', "$d/lazysite/stats/classifiers.json" or die $!;
print {$rf} '{"version":"test-1","rules":{"bot":"bot|crawl|spider|zephyrus"}}';
close $rf;

my $now = time;
my $ymd = strftime( '%Y%m%d',   localtime $now );
my $day = strftime( '%Y-%m-%d', localtime $now );
open my $lf, '>', "$d/lazysite/logs/access-$ymd.jsonl" or die $!;
print {$lf}
    qq({"t":$now,"p":"/","s":200,"ch":"page","v":"abcdef123456","ua":"Zephyrus/1.0"}\n);
close $lf;

sub run {
    my (@args) = @_;
    # t/lint/40: list form, never a shell string - an argument containing a
    # space would otherwise re-split and fail every assertion in the file.
    my $out = TestHelper::run_cmd( $^X, $PLUGIN, @args, '--docroot', $d );
    return decode_json( $out || '{}' );
}

sub day_file {
    open my $fh, '<', "$d/lazysite/stats/daily/$day.json" or return {};
    local $/;
    return decode_json(<$fh>);
}

my $e = run('--export');
is( $e->{classifier_version}, 'test-1', 'the export names the loaded ruleset' );
my $before = day_file();
is( $before->{classes}{bot}   // 0, 1, 'Zephyrus is a bot under the loaded rules' );
is( $before->{classes}{human} // 0, 0, 'and not a human' );

my $r = run( '--recount', '--apply' );
ok( $r->{ok}, 'the recount ran' ) or diag explain $r;
my $after = day_file();
is( $after->{classifier_version}, 'test-1',
    'the recount classified under the loaded ruleset, and says so' )
    or diag explain $after;
is( $after->{classes}{bot}   // 0, 1, 'Zephyrus is still a bot' );
is( $after->{classes}{human} // 0, 0, 'the recount did not invent a human' );

done_testing();
