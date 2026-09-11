#!/usr/bin/perl
# SM802: a per-domain prefix redirect, for a site replacing another on the same
# hostname while the old links are still in the world.
#
# The requirements are the reporter's, derived from a live migration rather
# than from taste, and each is asserted here: path and query preserved; prefix
# matched on a SEGMENT boundary (/web, never /website-terms); a real page always
# wins; 302 by default, 301 selectable; per-domain; the destination never taken
# from the request; and switched off, it does nothing at all.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_minimal_site site_tempdir run_processor);

my $d = site_tempdir();    # lint 118: not a bare tempdir
setup_minimal_site($d);
my $lz = "$d/lazysite";

make_path("$lz/remap");
open my $rf, '>', "$lz/remap/rules.conf" or die $!;
print {$rf} <<'CONF';
# host prefix destination [code]
www.example.com  /web       https://backend.example.com
www.example.com  /helpdesk  https://backend.example.com/support  301
CONF
close $rf;

# A real page under a remapped prefix: it must win.
make_path("$d/web");
open my $pf, '>', "$d/web/about.md" or die $!;
print {$pf} "---\ntitle: About\n---\n\nREAL-PAGE-BODY\n";
close $pf;

sub set_unit {
    my ($on) = @_;
    open my $cf, '>', "$lz/lazysite.conf" or die $!;
    print {$cf} "site_name: T\n";
    print {$cf} "extensions:\n  - plugins/remap.pl\n" if $on;
    close $cf;
}

sub get {
    my ( $path, %env ) = @_;
    my $out = run_processor( $d, $path, HTTP_HOST => 'www.example.com', %env ) // '';
    my ($st)  = $out =~ /^Status: (\d{3})/m;
    my ($loc) = $out =~ /^Location: ([^\r\n]*)/m;
    return ( $st // '200', $loc // '', $out );
}

# --- SWITCHED OFF, it does nothing ------------------------------------------
set_unit(0);
{
    my ( $st, $loc ) = get('/web/login');
    is( $loc, '', 'with the extension off, a matching path is not redirected' );
    is( $st, '404', '...it is the ordinary 404' );
}

set_unit(1);

# --- THE CANARY: the rule fires at all --------------------------------------
{
    my ( $st, $loc ) = get('/web/login');
    is( $st,  '302', 'with the extension on, a matching path redirects, 302 by default' );
    is( $loc, 'https://backend.example.com/login', 'the path under the prefix is kept' );
}

# --- the reporter's requirements --------------------------------------------
{
    my ( $st, $loc ) = get( '/web/order', QUERY_STRING => 'id=42&x=1' );
    is( $loc, 'https://backend.example.com/order?id=42&x=1',
        'the query string travels - a helpdesk link landing on a dashboard has not been redirected in any useful sense' );
}
{
    my ( $st, $loc ) = get('/web');
    is( $loc, 'https://backend.example.com', 'the prefix itself matches' );
}
{
    my ( $st, $loc ) = get('/website-terms');
    is( $loc, '', '/web does not match /website-terms - a segment boundary, not a startsWith' );
}
{
    my ( $st, $loc ) = get('/helpdesk/ticket/7');
    is( $st,  '301', 'a rule can choose 301' );
    is( $loc, 'https://backend.example.com/support/ticket/7', 'and a destination with its own path keeps it' );
}
{
    my ( $st, $loc, $out ) = get('/web/about');
    unlike( $loc, qr/backend/, 'a REAL PAGE under the prefix wins - a rule cannot shadow content' );
    like( $out, qr/REAL-PAGE-BODY/, '...the page is served' );
}
{
    my $out = run_processor( $d, '/web/login', HTTP_HOST => 'other.example.org' ) // '';
    unlike( $out, qr/^Location:/m, 'per-domain: another host on this instance is not redirected' );
}

# --- THE DESTINATION NEVER COMES FROM THE REQUEST ---------------------------
{
    my ( $st, $loc ) = get( '/web/x', QUERY_STRING => 'to=https://evil.example/' );
    like( $loc, qr{\Ahttps://backend\.example\.com/}, 'a ?to= in the request does not choose the destination' );
}

# --- the count's source is written -----------------------------------------
{
    get('/web/counted');
    my @logs = glob "$lz/logs/access-*.jsonl";
    my $all = join '', map { open my $l, '<', $_ or next; local $/; <$l> } @logs;
    like( $all, qr/"rr":"\/web"/, 'the redirect is recorded in the visitor log with its rule, so the count can be derived' );
}

done_testing();
