use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json encode_json);
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
    my ( $conf, %opt ) = @_;
    open my $cf, '>', "$d/lazysite/stats.conf" or die $!;
    print $cf $conf;
    close $cf;
    # The log path is an owner-set env var now, never manager config.
    local $ENV{LAZYSITE_ACCESS_LOG} = $opt{access_log} // '';
    local $ENV{LAZYSITE_ERROR_LOG}  = $opt{error_log}  // '';
    return decode_json( qx($^X $PLUGIN --scan --docroot '$d') );
}

my $s = scan( "window_days: 30\nanonymise_ip: true\nexclude_bots: true\n",
    access_log => "$d/access.log" );
ok( $s->{ok}, 'scan ok' ) or diag( $s->{error} );
is( $s->{hits}, 3, 'bot row excluded (3 of 4)' );
is( $s->{unique_visitors}, 1, 'anonymised IPs collapse to one' );
is( $s->{top_pages}[0]{key}, '/a', 'top page is /a' );
is( $s->{top_pages}[0]{count}, 2, '/a hit twice' );
is( $s->{status}{200}, 2, 'two 200s (non-bot)' );
is( $s->{status}{404}, 1, 'one 404' );
is( scalar @{ $s->{referrers}{external} }, 1, 'one external referrer' );

my $s2 = scan( "anonymise_ip: false\n", access_log => "$d/access.log" );
is( $s2->{classes}{human}{hits}, 3, 'human headline excludes the bot' );
is( $s2->{classes}{bot}{hits},   1, 'the Googlebot row is classed as a bot' );
is( $s2->{unique_visitors}, 2, 'raw human IPs when anonymise off (bot not counted)' );

# --- error-log surface: SYNTHESISED categories only, never raw lines / IPs / paths ---
open my $el, '>', "$d/error.log" or die $!;
print $el "[Sun Jun 28 00:47:58 2026] [proxy_fcgi:error] [pid 1:tid 2] [client 187.84.69.202:0] AH01071: Got error 'Primary script unknown'\n";
print $el "[Sun Jun 28 00:48:00 2026] [proxy_fcgi:error] [pid 1:tid 3] [client 10.0.0.1:0] AH01071: Got error 'Primary script unknown'\n";
print $el "[Sun Jun 28 02:00:00 2026] [core:error] [pid 1] AH00574: End of script output before headers: lazysite-auth.pl, referer: https://example.org/manager/config\n";
close $el;
my $se = scan( "", access_log => "$d/access.log", error_log => "$d/error.log" );
ok( $se->{errors} && $se->{errors}{available}, 'error log surfaced when set' );
ok( !exists $se->{errors}{recent}, 'raw recent error lines are NOT exposed' );
my %by = map { $_->{code} => $_ } @{ $se->{errors}{categories} || [] };
is( $by{AH01071}{count}, 2, 'scanner-probe errors counted' );
is( $by{AH00574}{count}, 1, 'no-headers CGI errors counted' );
like( $by{AH01071}{label}, qr/scanner|probe/i, 'friendly label, not the raw message' );
my $blob = encode_json( $se->{errors} );
unlike( $blob, qr/187\.84\.69\.202|10\.0\.0\.1/, 'no client IPs in the synthesis' );
unlike( $blob, qr/lazysite-auth\.pl|example\.org|referer/, 'no script names / referers / paths' );
ok( !exists $se->{error_log}, 'error-log disk path not exposed' );
ok( !exists $se->{log_download}, 'log_download flag removed (no raw download)' );

my $sne = scan( "", access_log => "$d/access.log", error_log => "$d/none.log" );
ok( !$sne->{errors}{available}, 'no error surface when the error log is missing' );

my $miss = scan( "", access_log => "$d/nope.log" );
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
    # Distinct page per log so we can tell which one auto-detect picked.
    for my $name ( 'demo.example.com.log', 'othersite.org.log' ) {
        open my $lf, '>', "$r/web/demo.example.com/logs/$name" or die $!;
        my $page = $name =~ /^demo/ ? '/demopage' : '/otherpage';
        print $lf qq{1.1.1.1 - - [$now] "GET $page HTTP/1.1" 200 10 "-" "Mozilla/5.0"\n};
        close $lf;
    }
    # A malicious manager-set access_log must be IGNORED (no arbitrary file read);
    # the path is owner/auto only.
    open my $sc, '>', "$doc/lazysite/stats.conf" or die $!;
    print $sc "window_days: 30\naccess_log: /etc/passwd\n";
    close $sc;
    my $got = decode_json( qx($^X $PLUGIN --scan --docroot '$doc') );
    ok( $got->{ok}, 'auto-detect scan ok (manager access_log ignored)' ) or diag( $got->{error} );
    ok( $got->{log_configured}, 'log resolved (its disk path is never returned)' );
    ok( !exists $got->{log}, 'disk path not exposed in the scan output (privacy)' );
    is( $got->{top_pages}[0]{key}, '/demopage',
        'auto-detect picked this site\x27s domain-qualified log, not the decoy' );
    ok( !( grep { ($_->{key}//'') eq '/otherpage' } @{ $got->{top_pages} } ),
        'did not read another site\x27s log' );
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
