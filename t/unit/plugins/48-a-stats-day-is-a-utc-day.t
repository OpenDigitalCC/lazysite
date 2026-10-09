#!/usr/bin/perl
# SM974 (Q14g): A STATS DAY IS A UTC DAY - for the writer, the reader and the
# judge of which day is closed.
#
# The processor files a first-party line by its UTC day and salts the visitor
# key with it; the stats ingester buckets by the same UTC day. The plugin then
# decided "today", "closed" and the window on the LOCAL calendar. East of UTC
# that judged the current UTC day closed at local midnight, finalised its day
# file, and never wrote it again: under BST the last hour of every UTC day
# never reached its durable record, under UTC+14 the last fourteen. SM343's
# frozen day, brought back by a time zone.
#
# It surfaced as three tests failing between local midnight and 01:00 BST. The
# tests had the same split in them, and so did the server-log parser (it read a
# stamp's wall-clock digits as local time and dropped the offset) and the
# form-event writer (a local date). This file holds the product to one
# calendar, at any hour: a POSIX zone 23:59 east of UTC puts the local date a
# day ahead of the UTC one for all but the first minute of every UTC day, so no
# fake clock is needed to stand in the window.
use strict;
use warnings;
use Test::More;
use JSON::PP    qw(decode_json encode_json);
use POSIX       qw(strftime);
use File::Path  qw(make_path);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir env_passthrough);

my $plugin  = repo_root() . '/plugins/stats.pl';
my $handler = repo_root() . '/plugins/form-handler.pl';
ok( -f $plugin, 'the stats plugin is present' );

# Three-letter name: glibc ignores a POSIX zone whose name is shorter.
my $EAST = '<QQQ>-23:59';

sub site {
    my $d = site_tempdir();
    make_path("$d/lazysite/$_") for qw(cache logs);
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_url: https://demo.example.io\n";
    close $cf;
    return $d;
}

sub export {
    my ( $d, $tz, %env ) = @_;
    local $ENV{TZ} = $tz;
    local @ENV{ keys %env } = values %env;
    open my $ph, '-|', $^X, $plugin, '--export', '--window', 30, '--docroot', $d
        or die "cannot run the plugin: $!";
    my $out = do { local $/; <$ph> };
    close $ph;
    return eval { decode_json($out) };
}

sub day_file {
    my ( $d, $day ) = @_;
    my $p = "$d/lazysite/stats/daily/$day.json";
    return {} unless -f $p;
    open my $fh, '<', $p or die $!;
    local $/;
    return decode_json(<$fh>);
}

subtest 'a UTC day east of UTC is not closed at local midnight' => sub {
    my $d   = site();
    my $T   = time;
    my $day = strftime( '%Y-%m-%d', gmtime $T );
    my $ymd = strftime( '%Y%m%d',   gmtime $T );
    my $log = "$d/lazysite/logs/access-$ymd.jsonl";

    # Two page views from two readers in the same UTC day, the second arriving
    # after the plugin has already run once. Both carry the same instant, so a
    # run that straddles UTC midnight cannot put them in different days.
    my $view = sub {
        my ($who) = @_;
        open my $fh, '>>', $log or die $!;
        print {$fh} encode_json( { t => $T, p => "/$who", s => 200, b => 100, ch => 'page',
                v => $who, ua => 'Mozilla/5.0 Chrome/120', r => '-' } ) . "\n";
        close $fh;
    };

    $view->('first');
    export( $d, $EAST );
    is( day_file( $d, $day )->{pageviews}, 1, 'the first run writes the UTC day' );

    $view->('second');
    export( $d, $EAST );
    is( day_file( $d, $day )->{pageviews}, 2,
        'and a later view in the same UTC day still reaches its file' )
        or diag( 'One means the day was finalised at LOCAL midnight while the '
            . 'UTC day it holds was still open, and everything after that '
            . 'point is missing from the only durable record the site keeps.' );
};

subtest 'a server-log stamp is read with its own offset' => sub {
    # 23:30 UTC yesterday, logged by a server at +0200: the wall clock reads
    # 01:30 TODAY. The instant is yesterday's, and so is its UTC day.
    my $d    = site();
    my $T    = int( time() / 86400 ) * 86400 - 1800;
    my $day  = strftime( '%Y-%m-%d',                gmtime $T );
    my $wall = strftime( '%d/%b/%Y:%H:%M:%S +0200', gmtime( $T + 7200 ) );
    my $log  = "$d/access.log";
    open my $lf, '>', $log or die $!;
    print {$lf} qq{198.51.100.4 - - [$wall] "GET /article HTTP/1.1" 200 100 "-" }
        . qq{"Mozilla/5.0 Chrome/120"\n};
    close $lf;

    export( $d, 'UTC', LAZYSITE_ACCESS_LOG => $log, DOCUMENT_ROOT => $d );
    is( day_file( $d, $day )->{pageviews}, 1,
        'the view is filed under the UTC day of its instant' )
        or diag( 'Filed under the wall-clock date means the offset was '
            . 'dropped, and a server logging in its own zone puts every view '
            . 'within that many hours of midnight on the wrong day.' );
};

subtest 'a form outcome is recorded on the UTC day' => sub {
    plan skip_all => "no $handler" unless -f $handler;
    my $SECRET  = 'c' x 64;
    my $docroot = site_tempdir();
    make_path("$docroot/lazysite/$_") for qw(forms auth);
    open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\n";
    close $cf;
    open my $hcf, '>', "$docroot/lazysite/forms/handlers.conf" or die $!;
    print {$hcf} "handlers:\n  - id: store\n    type: file\n    name: Store\n";
    close $hcf;
    open my $ff, '>', "$docroot/lazysite/forms/contact.conf" or die $!;
    print {$ff} "rate_limit: 0\ntargets:\n  - handler: store\n";
    close $ff;
    open my $fs, '>', "$docroot/lazysite/forms/.secret" or die $!;
    print {$fs} $SECRET;
    close $fs;

    my $ts   = time - 10;
    my $tk   = hmac_sha256_hex( $ts, $SECRET );
    my $body = "_form=contact&_hp=&_ts=$ts&_tk=$tk&name=x";
    my $bf   = "$docroot/.body";
    open my $b, '>', $bf or die $!;
    print {$b} $body;
    close $b;
    my $out = do {
        local %ENV = ( env_passthrough(),
            TZ             => $EAST,
            DOCUMENT_ROOT  => $docroot,
            REQUEST_METHOD => 'POST',
            CONTENT_TYPE   => 'application/x-www-form-urlencoded',
            CONTENT_LENGTH => length $body,
            REMOTE_ADDR    => '203.0.113.9',
            HTTP_ACCEPT    => 'application/json',
        );
        qx($^X \Q$handler\E < \Q$bf\E 2>/dev/null) // '';
    };
    like( $out, qr/"ok":1/, 'the submission was stored' ) or diag($out);

    my $after = strftime( '%Y-%m-%d', gmtime );
    opendir my $dh, "$docroot/lazysite/stats/form-events" or die $!;
    my @files = grep { /\.jsonl\z/ } readdir $dh;
    closedir $dh;
    is( scalar @files, 1, 'one form-event file' );
    my ($named) = ( $files[0] // '' ) =~ /^(\d{4}-\d{2}-\d{2})\.jsonl\z/;
    my $before = strftime( '%Y-%m-%d', gmtime( $ts + 10 ) );
    ok( defined $named && ( $named eq $before || $named eq $after ),
        'it is named by the UTC day' )
        or diag( "named $files[0], UTC day $after: a local date files the "
            . 'outcome under a different day bucket from the page views '
            . 'around it.' );
};

done_testing();
