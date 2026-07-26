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
is( $r->{schema_version}, '2', 'schema_version bumped to 2 (SM213)' );
is( $r->{totals}{human_visits}, 2, 'two human visits (the AI + scanner are not human)' );
is( $r->{traffic_classes}{ai}{visits},      1, 'one AI-assistant hit (ClaudeBot)' );
# SM213: visitor-level scanner classification - the wp-login probe marks its
# visitor a scanner, so it lands in the scanner class, not noise.
is( $r->{traffic_classes}{scanner}{visits}, 1, 'the wp-login probe is classed scanner (visitor-level)' );
is( $r->{traffic_classes}{noise}{visits},   0, 'and is no longer counted as generic noise' );
# SM213: 404 split - the probe 404 is junk (a scanner), not a plausible missing page.
is( $r->{not_found}{junk_count}, 1, 'the probe 404 counts as junk' );
is( scalar @{ $r->{not_found}{plausible} }, 0, 'no plausible (human) 404s here' );
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

# --- SM213: referrer spoofing + plausible 404, same batch -------------------
# A spoofer hits the homepage with a faked Reddit referrer AND probes a secret
# path moments later; visitor-level classing must pull its homepage hit out of the
# human/referrer buckets (not just flag the probe). A real person hitting a missing
# page is a plausible 404.
open my $ap2, '>>', $LOG or die $!;
print $ap2 line( '5.5.5.5', '/',            200, 'https://reddit.com/', 'Mozilla/5.0 Chrome/120' );
print $ap2 line( '5.5.5.5', '/secrets.json', 404, '-',                  'Mozilla/5.0 Chrome/120' );
print $ap2 line( '6.6.6.6', '/moved-page',   404, '-',                  'Mozilla/5.0 Safari/16' );
close $ap2;
my $r3 = run_export();
# Would be 5 if the spoofer's homepage counted (3 + spoofer / + the 6.6.6.6 human
# 404); it is 4, so the spoofer's homepage was pulled out (the +1 is the real 404).
is( $r3->{totals}{human_visits}, 4, 'spoofer homepage hit is NOT counted as human' );
ok( ( !grep { $_->{key} =~ /reddit/ } @{ $r3->{referrers}{external} } ),
    'spoofed reddit referrer is excluded (its visitor is a scanner)' );
ok( ( grep { $_->{key} eq '/moved-page' } @{ $r3->{not_found}{plausible} } ),
    'a human 404 on a real-looking path is a plausible missing page' );
cmp_ok( $r3->{traffic_classes}{scanner}{visits}, '>=', 3, 'scanner class now covers the spoofer + probes' );

# --- SM213: self-describing horizons + durable per-day store ----------------
my $today = strftime( '%Y-%m-%d', localtime );
my ($this_mon) = $today =~ /^(\d{4}-\d{2})/;

# Self-describing fields distinguish the complete aggregates from the raw sample.
ok( defined $r2->{data_from}, 'SM213: data_from present (how far the aggregates reach)' );
is( ref $r2->{sample}, 'HASH', 'SM213: sample block present' );
is( $r2->{sample}{count}, scalar @{ $r2->{events} }, 'SM213: sample.count matches the event ring' );
ok( defined $r2->{sample}{from} && defined $r2->{sample}{to}, 'SM213: sample states its from/to span' );
is( ref $r2->{months}, 'ARRAY', 'SM213: month-on-month series present' );
ok( ( grep { $_->{month} eq $this_mon } @{ $r2->{months} } ), 'SM213: current month in the series' );

# The durable store: a per-day file, a monthly rollup, and an index - OUTSIDE cache.
ok( -f "$d/lazysite/stats/daily/$today.json",     'SM213: durable per-day file written' );
ok( -f "$d/lazysite/stats/monthly/$this_mon.json", 'SM213: durable monthly rollup written' );
ok( -f "$d/lazysite/stats/index.json",            'SM213: durable index written' );

my $day = decode_json( do { open my $f, '<', "$d/lazysite/stats/daily/$today.json" or die $!; local $/; <$f> } );
is( $day->{date}, $today, 'day file is dated' );
is( $day->{pageviews}, 4, 'day rollup counts the human hits (incl. the human 404)' );
ok( exists $day->{top_pages} && exists $day->{classes}, 'day rollup carries aggregates' );
# Privacy: a durable day file holds aggregates only - no per-visitor list, no IP.
my $day_json = encode_json($day);
ok( !exists $day->{events} && !exists $day->{ips}, 'SM213: day file has no per-visitor records' );
unlike( $day_json, qr/\b\d+\.\d+\.\d+\.\d+\b/, 'SM213: no IP in a durable day file' );

# Selectors: --index / --day / --month return the durable slices.
sub run_sel {
    my (@a) = @_;
    local $ENV{DOCUMENT_ROOT}       = $d;
    local $ENV{LAZYSITE_ACCESS_LOG} = $LOG;
    return decode_json( qx($^X \Q$PLUGIN\E --export @a 2>/dev/null) );
}
my $idx = run_sel('--index');
ok( $idx->{ok} && $idx->{data_from} && ref $idx->{days} eq 'ARRAY' && ref $idx->{months} eq 'ARRAY',
    'SM213: --index returns the days + months index' );
my $dsel = run_sel( '--day', $today );
ok( $dsel->{ok} && $dsel->{day}{date} eq $today, 'SM213: --day returns that day rollup' );
my $msel = run_sel( '--month', $this_mon );
ok( $msel->{ok} && $msel->{month}{month} eq $this_mon, 'SM213: --month returns that month rollup' );
my $bad = run_sel( '--day', '2000-01-01' );
ok( !$bad->{ok}, 'SM213: an absent day is a clean not-found, not a crash' );

done_testing;
