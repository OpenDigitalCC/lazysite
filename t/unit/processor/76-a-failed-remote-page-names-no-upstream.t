#!/usr/bin/perl
# SM837: a .url page whose fetch fails tells the visitor the content is
# unavailable, and nothing about where it comes from.
#
# Found proving SM797: /upstream.url.url had to be compared with /upstream, and
# BOTH carried the upstream address - because the failure path rendered "Could
# not fetch remote content from <code>$url</code>": the address, to an anonymous
# visitor, interpolated unescaped, as a 200. A .url source can name an internal
# host or carry a token; the operator published the content, never the address.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_minimal_site site_tempdir run_processor);

my $d = site_tempdir();    # lint 118: not a bare tempdir
setup_minimal_site($d);

# An upstream that cannot answer: a closed port on loopback, with a token in the
# query and an internal-looking path - the things an address should never leak.
open my $u, '>', "$d/remote.url" or die $!;
print {$u} "http://127.0.0.1:1/internal/SECRET-PATH?token=SECRET-TOKEN\n";
close $u;

my $out = run_processor( $d, '/remote' ) // '';
my ($status) = $out =~ /^Status: (\d{3})/m;
my ($body)   = $out =~ /\r?\n\r?\n(.*)\z/s;
$body //= '';

# --- THE CANARY -------------------------------------------------------------
# "The address is absent" passes against a page that rendered nothing at all, so
# first prove this is the failure page.
like( $body, qr/temporarily unavailable/, 'the rig reached the failure page' );

# --- THE FINDING ------------------------------------------------------------
unlike( $body, qr/SECRET-TOKEN/,  'the upstream token does not reach the visitor' );
unlike( $body, qr/SECRET-PATH/,   'nor the upstream path' );
unlike( $body, qr/127\.0\.0\.1/,  'nor the upstream host' );
is( $status, '503', 'and it answers 503, not a 200 that caches and monitors believe' );

done_testing();
