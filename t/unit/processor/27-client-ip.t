#!/usr/bin/perl
# SM135: the visitor's IP as a live TT variable on a nocache page.
# client_ip = X-Forwarded-For first hop (client behind a proxy) else REMOTE_ADDR;
# `nocache: true` renders fresh per request (never cached), so the IP is the
# current visitor's, not a baked one.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_minimal_site run_processor);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);

open my $p, '>', "$docroot/ip.md" or die $!;
print $p "---\ntitle: Your IP\nnocache: true\n---\n\nMYIP:[% client_ip %]:END\n";
close $p;

# --- REMOTE_ADDR is used when there is no forwarded header ---
my $o1 = run_processor( $docroot, '/ip',
    REMOTE_ADDR => '203.0.113.7', HTTP_X_FORWARDED_FOR => undef );
like( $o1, qr/MYIP:\s*203\.0\.113\.7:END/, 'renders REMOTE_ADDR when no X-Forwarded-For' );

# --- X-Forwarded-For first hop wins (the real client behind a proxy) ---
my $o2 = run_processor( $docroot, '/ip',
    REMOTE_ADDR => '10.0.0.1', HTTP_X_FORWARDED_FOR => '198.51.100.9, 10.0.0.1' );
like( $o2, qr/MYIP:\s*198\.51\.100\.9:END/, 'renders the X-Forwarded-For first hop when present' );

# --- nocache: nothing is written to the page cache ---
ok( !-f "$docroot/ip.html", 'a nocache page is not written to the cache' );

# --- per request: a later request shows the new IP, not a baked one ---
my $o3 = run_processor( $docroot, '/ip',
    REMOTE_ADDR => '192.0.2.55', HTTP_X_FORWARDED_FOR => undef );
like( $o3, qr/MYIP:\s*192\.0\.2\.55:END/, 'a later request shows the new visitor IP (live)' );
ok( !-f "$docroot/ip.html", 'still not cached after a second request' );

# --- markup characters in a spoofed forwarded header are stripped ---
my $o4 = run_processor( $docroot, '/ip',
    REMOTE_ADDR => '10.0.0.1', HTTP_X_FORWARDED_FOR => '1.2.3.4<>"' );
like( $o4, qr/MYIP:\s*1\.2\.3\.4:END/, 'non-IP characters are stripped from the forwarded value' );

done_testing();
