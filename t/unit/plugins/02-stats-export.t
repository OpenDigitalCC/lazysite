use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json encode_json);
use POSIX qw(strftime);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

# The AI visitor-stats export: a SANITISED, cached, incremental JSON the agent
# reasons over - aggregates + an event stream, never the raw log, a filesystem
# path, or a visitor IP.
my $PLUGIN = repo_root() . '/plugins/stats.pl';
ok( -f $PLUGIN, 'stats plugin present' );

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/cache");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "site_url: https://demo.example.io\n";
close $cf;
my $LOG = "$d/access.log";
my $NOW = strftime( '%d/%b/%Y:%H:%M:%S +0000', localtime );

sub line {
    my ( $ip, $path, $status, $ref, $ua ) = @_;
    return qq{$ip - - [$NOW] "GET $path HTTP/1.1" $status 100 "$ref" "$ua"\n};
}

open my $lf, '>', $LOG or die $!;
print $lf line( '1.2.3.4', '/about', 200, 'https://google.com/', 'Mozilla/5.0 Chrome/120' );
print $lf line( '1.2.3.5', '/about', 200, '-',                    'Mozilla/5.0 Safari/16' );
print $lf line( '9.9.9.9', '/x',     200, '-',                    'ClaudeBot/1.0' );
print $lf line( '8.8.8.8', '/wp-login.php', 404, '-',             'curl/8' );
close $lf;

sub run_export {
    local $ENV{DOCUMENT_ROOT}      = $d;
    local $ENV{LAZYSITE_ACCESS_LOG} = $LOG;
    my $out = qx($^X \Q$PLUGIN\E --export --window 30 2>/dev/null);
    return decode_json($out);
}

my $r = run_export();
ok( $r->{ok}, 'export ok' );
is( $r->{schema_version}, '1', 'schema_version present' );
is( $r->{totals}{human_visits}, 2, 'two human visits (the AI + scanner are not human)' );
is( $r->{traffic_classes}{ai}{visits},    1, 'one AI-assistant hit (ClaudeBot)' );
is( $r->{traffic_classes}{noise}{visits}, 1, 'one noise hit (wp-login probe)' );
is( $r->{top_pages}[0]{key}, '/about', 'top human page is /about' );
ok( @{ $r->{by_day} } >= 1, 'by_day trend present' );
is( scalar @{ $r->{events} }, 4, 'event stream has all four requests' );

# Privacy: the raw IP and any filesystem path must NOT appear anywhere.
my $json = encode_json($r);
unlike( $json, qr/\b1\.2\.3\.4\b/, 'no raw visitor IP in the export' );
unlike( $json, qr/\Q$d\E/,         'no docroot/filesystem path in the export' );
ok( exists $r->{events}[0]{visitor}, 'events carry a (hashed) visitor token, not an IP' );
unlike( encode_json( $r->{events}[0] ), qr/\b\d+\.\d+\.\d+\.\d+\b/, 'no IP address in an event' );

# Incremental cache: appending a human line is picked up; the offset tracks size.
open my $ap, '>>', $LOG or die $!;
print $ap line( '7.7.7.7', '/docs', 200, '-', 'Mozilla/5.0 Chrome/120' );
close $ap;
my $r2 = run_export();
is( $r2->{totals}{human_visits}, 3, 'incremental: appended human line counted' );
is( scalar @{ $r2->{events} }, 5, 'incremental: appended event added' );

open my $ch, '<', "$d/lazysite/cache/stats-export.json" or die $!;
my $cache = decode_json( do { local $/; <$ch> } );
close $ch;
is( $cache->{offset}, -s $LOG, 'cache offset matches the log size (clean boundary)' );

done_testing;
