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
is( scalar @{ $s->{top_referrers} }, 1, 'one external referrer' );

my $s2 = scan("access_log: $d/access.log\nexclude_bots: false\nanonymise_ip: false\n");
is( $s2->{hits}, 4, 'bots included when disabled' );
is( $s2->{unique_visitors}, 3, 'raw IPs when anonymise off' );

my $miss = scan("access_log: $d/nope.log\n");
ok( !$miss->{ok}, 'unreadable log -> ok:0 with a message' );
like( $miss->{error}, qr/readable|configured/i, 'helpful error' );

done_testing;
