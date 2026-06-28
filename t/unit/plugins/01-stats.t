use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use File::Temp qw(tempdir);
use POSIX qw(strftime);

# SM083: the visitor-stats plugin parses the access log into aggregates.
my $PLUGIN = 'plugins/stats.pl';
ok( -f $PLUGIN, 'stats plugin present' );

my $desc = decode_json( qx($^X $PLUGIN --describe) );
is( $desc->{id}, 'stats', '--describe: id is stats' );
ok( @{ $desc->{config_schema} } >= 4, '--describe: config schema present' );
ok( @{ $desc->{actions} } >= 1, '--describe: has an action' );

my $d = tempdir( CLEANUP => 1 );
mkdir "$d/lazysite";
my $now = strftime( '%d/%b/%Y:%H:%M:%S +0000', localtime );
open my $lg, '>', "$d/access.log" or die $!;
print $lg qq{1.2.3.4 - - [$now] "GET /a HTTP/1.1" 200 100 "https://ext.example/" "Mozilla/5.0"\n};
print $lg qq{1.2.3.5 - - [$now] "GET /a HTTP/1.1" 200 100 "-" "Mozilla/5.0"\n};
print $lg qq{9.9.9.9 - - [$now] "GET /b HTTP/1.1" 200 100 "-" "Googlebot/2.1"\n};
print $lg qq{1.2.3.4 - - [$now] "GET /x HTTP/1.1" 404 50 "-" "Mozilla/5.0"\n};
close $lg;

sub scan {
    my ($conf) = @_;
    open my $cf, '>', "$d/lazysite/stats.conf" or die $!;
    print $cf $conf;
    close $cf;
    return decode_json( qx($^X $PLUGIN --scan --docroot '$d') );
}

my $s = scan("access_log: $d/access.log\nwindow_days: 30\nanonymise_ip: true\nexclude_bots: true\n");
ok( $s->{ok}, 'scan ok' ) or diag( $s->{error} );
is( $s->{hits}, 3, 'bot row excluded (3 of 4)' );
is( $s->{unique_visitors}, 1, 'anonymised IPs collapse to one' );
is( $s->{top_pages}[0]{key}, '/a', 'top page is /a' );
is( $s->{top_pages}[0]{count}, 2, '/a hit twice' );
is( $s->{status}{200}, 2, 'two 200s (non-bot)' );
is( $s->{status}{404}, 1, 'one 404' );
is( scalar @{ $s->{referrers}{external} }, 1, 'one external referrer' );

my $s2 = scan("access_log: $d/access.log\nanonymise_ip: false\n");
is( $s2->{classes}{human}{hits}, 3, 'human headline excludes the bot' );
is( $s2->{classes}{bot}{hits},   1, 'the Googlebot row is classed as a bot' );
is( $s2->{unique_visitors}, 2, 'raw human IPs when anonymise off (bot not counted)' );

my $miss = scan("access_log: $d/nope.log\n");
ok( !$miss->{ok}, 'unreadable log -> ok:0 with a message' );
like( $miss->{error}, qr/readable|found|configured/i, 'helpful error' );

# --- domain-qualified auto-detect: pick this site's log, not a decoy ---
{
    my $r = tempdir( CLEANUP => 1 );
    my $doc = "$r/web/demo.example.com/public_html";
    mkdir "$r/web"; mkdir "$r/web/demo.example.com";
    mkdir $doc; mkdir "$doc/lazysite"; mkdir "$r/web/demo.example.com/logs";
    open my $cf, '>', "$doc/lazysite/lazysite.conf" or die $!;
    print $cf "site_url: https://demo.example.com\n";
    close $cf;
    for my $name ( 'demo.example.com.log', 'othersite.org.log' ) {
        open my $lf, '>', "$r/web/demo.example.com/logs/$name" or die $!;
        my $ip = $name =~ /^demo/ ? '1.1.1.1' : '9.9.9.9';
        print $lf qq{$ip - - [$now] "GET /p HTTP/1.1" 200 10 "-" "Mozilla/5.0"\n};
        close $lf;
    }
    open my $sc, '>', "$doc/lazysite/stats.conf" or die $!;   # no access_log -> auto-detect
    print $sc "window_days: 30\n";
    close $sc;
    my $got = decode_json( qx($^X $PLUGIN --scan --docroot '$doc') );
    ok( $got->{ok}, 'auto-detect scan ok' ) or diag( $got->{error} );
    ok( $got->{log_configured}, 'log resolved (its disk path is never returned)' );
    ok( !exists $got->{log}, 'disk path not exposed in the scan output (privacy)' );
    open my $rd, '<', "$doc/lazysite/stats.conf" or die $!;
    my $conf = do { local $/; <$rd> };
    close $rd;
    like( $conf, qr/access_log:.*demo\.example\.com\.log/, 'autoconfig persisted the domain-qualified path' );
    unlike( $conf, qr/othersite/, 'did not pick another site\x27s log' );
}

# --- not found -> needs_config, so the page asks ---
{
    my $r2 = tempdir( CLEANUP => 1 );
    my $doc2 = "$r2/web/none.example/public_html";
    mkdir "$r2/web"; mkdir "$r2/web/none.example"; mkdir $doc2; mkdir "$doc2/lazysite";
    open my $cf2, '>', "$doc2/lazysite/lazysite.conf" or die $!;
    print $cf2 "site_url: https://none.example\n";
    close $cf2;
    open my $sc2, '>', "$doc2/lazysite/stats.conf" or die $!; close $sc2;
    my $none = decode_json( qx($^X $PLUGIN --scan --docroot '$doc2') );
    ok( !$none->{ok} && $none->{needs_config}, 'no log found -> needs_config (ask the operator)' );
}

done_testing;
