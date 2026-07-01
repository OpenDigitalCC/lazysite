#!/usr/bin/perl
# stats.pl classifier (SM083 v2): end-to-end over a fixture access log. Verifies
# the five traffic classes (human / ai / bot / noise / logged_in), the
# internal/external/direct referrer split, that top pages exclude manager+probes,
# and that the disk path of the log is never returned (privacy).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root   = repo_root();
my $plugin = "$root/plugins/stats.pl";
my $doc    = tempdir( CLEANUP => 1 );
make_path("$doc/lazysite");

my $logf = "$doc/access.log";
open my $lf, '>', $logf or die $!;
my $D = '15/Jan/2026:10:00:00 +0000';
my @lines = (
    # --- genuine humans (3 distinct IPs): external, internal, direct referrers
    qq{1.2.3.4 - - [$D] "GET /about HTTP/1.1" 200 1234 "https://example.com/" "Mozilla/5.0 (X11; Linux) Gecko Firefox/120"},
    qq{1.2.3.5 - - [$D] "GET /contact HTTP/1.1" 200 500 "https://mysite.test/about" "Mozilla/5.0 (Windows) Chrome/120"},
    qq{1.2.3.6 - - [$D] "GET / HTTP/1.1" 200 800 "-" "Mozilla/5.0 (Macintosh) Safari/17"},
    # --- AI: by UA, and by automation endpoint hit from a non-browser client
    qq{5.5.5.5 - - [$D] "GET / HTTP/1.1" 200 800 "-" "GPTBot/1.2"},
    qq{6.6.6.6 - - [$D] "POST /cgi-bin/lazysite-manager-api.pl?action=whoami HTTP/1.1" 200 50 "-" "lazysite-connector/1"},
    # --- bot: UA-detected crawler on a content path
    qq{7.7.7.7 - - [$D] "GET /pricing HTTP/1.1" 200 50 "-" "Googlebot/2.1"},
    # --- bot: Chrome --headless=new default UA (HeadlessChrome token)
    qq{11.1.1.1 - - [$D] "GET /features HTTP/1.1" 200 800 "-" "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/149.0.0.0 Safari/537.36"},
    # --- bot: self-identifying lazysite tooling (opt-out UA convention)
    qq{11.1.1.2 - - [$D] "GET /comparison HTTP/1.1" 200 800 "-" "claude-code-agent/lazysite"},
    qq{11.1.1.3 - - [$D] "GET /comparison HTTP/1.1" 200 800 "-" "Mozilla/5.0 lazysite-agent/claude-dhcf"},
    # --- noise: wp-login probe, and any .php on a PHP-less site (even browser UA)
    qq{8.8.8.8 - - [$D] "GET /wp-login.php HTTP/1.1" 404 0 "-" "curl/7.88"},
    qq{9.9.9.9 - - [$D] "GET /index.php HTTP/1.1" 404 0 "-" "Mozilla/5.0 (Windows) Chrome/120"},
    # --- noise: infra fetches ride along with real visits but are not page views
    qq{1.2.3.4 - - [$D] "GET /favicon.ico HTTP/1.1" 200 100 "-" "Mozilla/5.0 (X11; Linux) Gecko Firefox/120"},
    qq{1.2.3.9 - - [$D] "GET /robots.txt HTTP/1.1" 200 50 "-" "Mozilla/5.0 (Windows) Chrome/120"},
    # --- logged-in operator: manager surface + manager-api from a real browser
    qq{10.0.0.1 - - [$D] "GET /manager/files HTTP/1.1" 200 1000 "-" "Mozilla/5.0 (Windows) Chrome/120"},
    qq{10.0.0.1 - - [$D] "POST /cgi-bin/lazysite-manager-api.pl?action=files-list HTTP/1.1" 200 200 "-" "Mozilla/5.0 (Windows) Chrome/120"},
);
print $lf "$_\n" for @lines;
close $lf;

open my $cf, '>', "$doc/lazysite/stats.conf" or die $!;
print $cf "window_days: 36500\n";       # so the fixed fixture date is always in-window
print $cf "anonymise_ip: false\n";      # test exact unique-visitor counts
close $cf;

# The log path is now an owner-set env var, not manager config.
$ENV{LAZYSITE_ACCESS_LOG} = $logf;

open my $lc, '>', "$doc/lazysite/lazysite.conf" or die $!;
print $lc "site_url: https://mysite.test\n";
close $lc;

my $json = qx{$^X \Q$plugin\E --scan --docroot \Q$doc\E 2>&1};
my $r = eval { decode_json($json) };
ok( $r && $r->{ok}, 'scan ok' ) or diag $json;

my $c = $r->{classes};
is( $c->{human}{hits},     3, 'human hits' );
is( $c->{human}{visitors}, 3, 'human unique visitors' );
is( $c->{ai}{hits},        2, 'ai hits (UA + connector endpoint)' );
is( $c->{bot}{hits},       4, 'bot hits (Googlebot + HeadlessChrome + 2 self-identified agents)' );
is( $c->{noise}{hits},     4, 'noise hits (wp-login + .php + favicon + robots)' );
is( $c->{logged_in}{hits}, 2, 'logged-in operator hits' );
is( $c->{logged_in}{visitors}, 1, 'logged-in one IP' );

is( $r->{hits},            3, 'headline hits = human only' );
is( $r->{unique_visitors}, 3, 'headline visitors = human only' );

is( $r->{referrers}{internal}, 1, 'one self-referrer' );
is( $r->{referrers}{direct},   1, 'one direct hit' );
is( scalar @{ $r->{referrers}{external} }, 1, 'one external referrer' );
like( $r->{referrers}{external}[0]{key}, qr/example\.com/, 'external referrer is example.com' );

my %pages = map { $_->{key} => 1 } @{ $r->{top_pages} };
ok( $pages{'/about'} && $pages{'/contact'} && $pages{'/'}, 'human pages listed' );
ok( !$pages{'/manager/files'} && !$pages{'/wp-login.php'} && !$pages{'/index.php'},
    'manager + probe paths excluded from top pages' );

ok( !exists $r->{log}, 'disk path of the log is NOT returned (privacy)' );
ok( $r->{log_configured}, 'log_configured flag present instead' );

done_testing;
