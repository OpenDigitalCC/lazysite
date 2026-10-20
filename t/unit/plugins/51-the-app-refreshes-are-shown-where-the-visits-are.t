#!/usr/bin/perl
# SM1212: SM1203 counted the installed app's own page fetches (channel `app`) in
# the day rollup as app_hits, and nothing read them. The window view the manager
# draws, the window answer of the export (the control API and MCP analyse_visitors)
# and each month carry the figure, summed over the days, beside pageviews and not
# inside them. A site whose app made none sees no new field.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $root   = repo_root();
my $plugin = "$root/plugins/stats.pl";
plan skip_all => "no $plugin" unless -f $plugin;

# Two days, 90 minutes back and a day and a half back, clear of UTC midnight.
my $now = time();
my @recs;
for my $back ( 5400, 5400 + 86400 ) {
    my $t     = $now - $back;
    my $spill = $t % 86400;
    $t -= $spill + 1 + 600 if $spill < 600;    # keep the fixture inside one UTC day
    push @recs, $t;
}

sub site_with {
    my ($with_app) = @_;
    my $d = site_tempdir();
    make_path( "$d/lazysite/logs", "$d/lazysite/stats", "$d/lazysite/cache" );
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_url: https://d.example.io\nwindow_days: 30\n";
    close $cf;
    my $i = 0;
    for my $rec (@recs) {
        my @gm  = gmtime($rec);
        my $ymd = sprintf '%04d%02d%02d', $gm[5] + 1900, $gm[4] + 1, $gm[3];
        open my $lf, '>', "$d/lazysite/logs/access-$ymd.jsonl" or die $!;
        my $ev = sub {
            my ( $path, $ch, $v ) = @_;
            printf {$lf} qq({"t":%d,"p":"%s","s":200,"ch":"%s","v":"%s","ua":"Mozilla/5.0 Chrome/120"}\n),
                $rec + ( $i++ * 10 ), $path, $ch, $v;
        };
        $ev->( '/portal/', 'page', 'V1' );
        if ($with_app) {
            $ev->( '/portal/', 'app', 'V1' );
            $ev->( '/about',   'app', 'V1' );
        }
        close $lf;
    }
    return $d;
}

sub run {
    my ( $d, @args ) = @_;
    # Argument list, never a shell string (t/lint/40); stdout only, as it is JSON.
    local $ENV{DOCUMENT_ROOT} = $d;
    open my $ph, '-|', $^X, $plugin, @args, '--docroot', $d or die "cannot run $plugin: $!";
    my $out = do { local $/; <$ph> };
    close $ph;
    return eval { decode_json($out) } || {};
}

my $d = site_with(1);

my $view = run( $d, '--scan' );
ok( $view->{ok}, 'the window view answers' );
is( $view->{app_hits}, 4, 'the view the manager draws carries the fetches, summed over the days' );
is( $view->{hits}, 2, 'and the page views are the two visits, not the visits plus the fetches' );

my $exp = run( $d, '--export', '--window', '30' );
ok( $exp->{ok}, 'the export answers' );
is( $exp->{totals}{app_hits}, 4, 'the API and MCP window answer carries app_hits in totals' );
is( $exp->{totals}{pageviews}, 2, 'beside pageviews, which do not include them' );

my $mon = sprintf '%04d-%02d', ( gmtime $recs[0] )[5] + 1900, ( gmtime $recs[0] )[4] + 1;
my $m   = run( $d, '--export', '--month', $mon );
ok( $m->{ok}, 'the month rollup answers' );
is( $m->{month}{app_hits}, 4, 'a month carries the figure, summed over its days' ) if $mon eq sprintf( '%04d-%02d', ( gmtime $recs[1] )[5] + 1900, ( gmtime $recs[1] )[4] + 1 );
cmp_ok( $m->{month}{app_hits} // 0, '>=', 2, 'a month carries the figure' );

my $e  = site_with(0);
my $v0 = run( $e, '--scan' );
ok( !exists $v0->{app_hits}, 'a site with no app fetches gets no app_hits in the view' );
my $x0 = run( $e, '--export', '--window', '30' );
ok( !exists $x0->{totals}{app_hits}, 'nor in the export totals' );

done_testing();
