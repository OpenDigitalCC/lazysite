#!/usr/bin/perl
# SM135: the visitor's IP as a live TT variable on a nocache page.
# SM929: AND IT IS NOW TRUSTWORTHY, which it was not.
#
# `client_ip` took the FIRST hop of X-Forwarded-For whenever the header was
# present, with no trust check of any kind. MEASURED ON A LIVE SITE 2026-10-01:
# a request carrying `X-Forwarded-For: 203.0.113.7` rendered 203.0.113.7, so any
# visitor could choose what the page said about them - and whatever a site did with
# that value (print it, log it, store it) recorded a string they chose.
#
# The two cases that matter are the forgeries, one on each side of the trust line:
#   - a DIRECTLY-served site ignores the header entirely, because the peer is not a
#     trusted proxy (test 3);
#   - BEHIND a trusted proxy, a caller who sends their own header has it appended
#     to rather than believed, so the rightmost hop - the one the proxy itself
#     contributed - wins over the one the caller invented (test 4).
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

# --- behind a trusted proxy, the visitor rather than the proxy ---
# No trusted_proxies set, so the shipped RFC1918 default decides, and 10.0.0.1 is
# in it. This is the case SM929 was raised about: every submission on the site
# recorded the proxy because this was the only reader that looked past it.
my $o2 = run_processor( $docroot, '/ip',
    REMOTE_ADDR => '10.0.0.1', HTTP_X_FORWARDED_FOR => '198.51.100.9, 10.0.0.1' );
like( $o2, qr/MYIP:\s*198\.51\.100\.9:END/, 'renders the visitor behind a trusted proxy' );

# --- A DIRECTLY-SERVED SITE IGNORES THE HEADER ---
my $o3 = run_processor( $docroot, '/ip',
    REMOTE_ADDR => '203.0.113.9', HTTP_X_FORWARDED_FOR => '198.51.100.9' );
like( $o3, qr/MYIP:\s*203\.0\.113\.9:END/,
    'an untrusted peer that sends a forwarded header is still just the peer' );
unlike( $o3, qr/198\.51\.100\.9/,
    'and the address it asked to be called does not reach the page' );

# --- THROUGH a trusted proxy, a forged hop loses to the appended one ---
my $o4 = run_processor( $docroot, '/ip',
    REMOTE_ADDR          => '10.0.0.1',
    HTTP_X_FORWARDED_FOR => '203.0.113.7, 198.51.100.9' );
like( $o4, qr/MYIP:\s*198\.51\.100\.9:END/,
    'the hop the proxy appended wins over the one the caller sent' );
unlike( $o4, qr/203\.0\.113\.7/, 'the forged first hop is not what renders' );

# --- nocache: nothing is written to the page cache ---
ok( !-f "$docroot/ip.html", 'a nocache page is not written to the cache' );

# --- per request: a later request shows the new IP, not a baked one ---
my $o5 = run_processor( $docroot, '/ip',
    REMOTE_ADDR => '192.0.2.55', HTTP_X_FORWARDED_FOR => undef );
like( $o5, qr/MYIP:\s*192\.0\.2\.55:END/, 'a later request shows the new visitor IP (live)' );
ok( !-f "$docroot/ip.html", 'still not cached after a second request' );

# --- a forwarded value that is not an address is IGNORED, not salvaged -------
# This used to be stripped to its address-shaped characters and then believed.
# Stripping defended the PAGE (no markup reaches the output) and said nothing
# about whether the value was true. A hop that will not parse now ends the walk,
# so the answer falls back to the peer - and the sanitiser stays as depth behind
# it rather than as the only defence.
my $o6 = run_processor( $docroot, '/ip',
    REMOTE_ADDR => '10.0.0.1', HTTP_X_FORWARDED_FOR => '1.2.3.4<>"' );
like( $o6, qr/MYIP:\s*10\.0\.0\.1:END/,
    'a malformed forwarded value falls back to the peer' );
# Scoped to the rendered SPAN, not the whole page: the layout around it is HTML
# and full of quotes and angle brackets, so a document-wide check would pass or
# fail for reasons that have nothing to do with the forwarded value.
my ($span) = $o6 =~ /MYIP:(.*?):END/s;
unlike( $span, qr/[<>"]/, 'and no markup character reaches the value itself' );

done_testing();
