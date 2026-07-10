#!/usr/bin/perl
# SM140: the processor records its own traffic (first-party access log) so
# visitor analytics need no web-server log. Pins the recorder end-to-end
# (statuses, channels, cache flag, anonymised visitor key, injection
# sanitisation, the off switch, retention prune) and the stats plugin's
# first-party aggregation.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor repo_root);

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/manager", "$d/lazysite/auth", "$d/manager" );
open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
print $c "site_name: T\nmanager: enabled\nauth_proxy_trusted: true\n";
close $c;
open my $g, '>', "$d/lazysite/auth/groups-settings.json" or die $!;
print $g '{"admins":{"label":"Admins","ui":1}}';
close $g;
open my $m, '>', "$d/manager/config.md" or die $!;
print $m "---\ntitle: S\nauth: manager\n---\nSETTINGS\n";
close $m;
open my $i, '>', "$d/index.md" or die $!;
print $i "---\ntitle: Home\n---\nHOME\n";
close $i;

my $UA = 'Mozilla/5.0 (X11; Linux) TestBrowser';
my ($today) = do { my @t = gmtime; sprintf '%04d%02d%02d', $t[5] + 1900, $t[4] + 1, $t[3] };
my $log = "$d/lazysite/logs/access-$today.jsonl";

sub log_lines {
    open my $fh, '<', $log or return ();
    my @l = map { eval { decode_json($_) } || () } <$fh>;
    close $fh;
    return @l;
}

# A stale day-file from beyond retention: the first write of a new day prunes it.
make_path("$d/lazysite/logs");
open my $old, '>', "$d/lazysite/logs/access-20200101.jsonl" or die $!;
print $old "{}\n";
close $old;

run_processor( $d, '/', REMOTE_ADDR => '198.51.100.7', HTTP_USER_AGENT => $UA );
run_processor( $d, '/nope', REMOTE_ADDR => '198.51.100.8', HTTP_USER_AGENT => $UA,
    HTTP_REFERER => 'https://search.example/q' );
run_processor( $d, '/manager/config', REMOTE_ADDR => '198.51.100.7',
    HTTP_USER_AGENT => $UA, HTTP_X_REMOTE_USER => 'alice', HTTP_X_REMOTE_GROUPS => 'admins' );
run_processor( $d, '/', REMOTE_ADDR => '198.51.100.7',
    HTTP_USER_AGENT => "Bad\x0aAgent\x09Ctl" );    # cache hit + injection attempt

my @lines = log_lines();
is( scalar @lines, 4, 'one line per request' );

is( $lines[0]{s},  200,    'page view recorded as 200' );
is( $lines[0]{p},  '/',    'path recorded' );
is( $lines[0]{ch}, 'page', 'visitor channel' );
is( $lines[0]{ua}, $UA,    'user agent recorded' );
ok( $lines[0]{b} > 0, 'bytes recorded' );
like( $lines[0]{v}, qr/^[0-9a-f]{16}$/, 'visitor key is a 16-hex hash' );

is( $lines[1]{s}, 404, 'missing page recorded as 404' );
is( $lines[1]{r}, 'https://search.example/q', 'referrer recorded' );

is( $lines[2]{ch}, 'manager', 'manager traffic channel-tagged' );

is( $lines[3]{c}, 1, 'second hit on / served from cache and flagged' );
is( $lines[3]{ua}, 'BadAgentCtl', 'control characters stripped (log injection)' );

# Anonymisation: raw IPs never in the file; same ip+day -> same key, different
# ip -> different key.
my $raw = do { local ( @ARGV, $/ ) = ($log); <> };
unlike( $raw, qr/198\.51\.100/, 'no raw IP anywhere in the log' );
is( $lines[0]{v}, $lines[2]{v}, 'same visitor+day -> same key' );
isnt( $lines[0]{v}, $lines[1]{v}, 'different visitor -> different key' );

ok( !-e "$d/lazysite/logs/access-20200101.jsonl",
    'day-file beyond retention pruned on the first write of a new day' );

# --- stats plugin aggregates the first-party data (SM140 increment 2) ---
my $root = repo_root();
open my $sc, '>', "$d/lazysite/stats.conf" or die $!;
print $sc "window_days: 30\n";
close $sc;
my $s = decode_json( qx($^X $root/plugins/stats.pl --scan --docroot '$d') );
ok( $s->{ok}, 'first-party scan ok' ) or diag( $s->{error} );
is( $s->{source}, 'first-party', 'source is the first-party log' );
is( $s->{hits}, 3, 'human page hits: /, /nope, / cache hit (manager excluded)' );
is( $s->{unique_visitors}, 2, 'distinct daily visitor keys' );
is( $s->{status}{404}, 1, '404 in the status histogram' );
is( $s->{top_pages}[0]{key}, '/', 'top page from first-party data' );
is( scalar @{ $s->{referrers}{external} }, 1, 'external referrer counted' );
ok( $s->{anonymised}, 'reported as anonymised' );

# --- the off switch: first_party: off stops recording ---
open $sc, '>', "$d/lazysite/stats.conf" or die $!;
print $sc "first_party: off\n";
close $sc;
run_processor( $d, '/', REMOTE_ADDR => '198.51.100.9', HTTP_USER_AGENT => $UA );
is( scalar log_lines(), 4, 'no line recorded when first_party is off' );

done_testing;
