#!/usr/bin/perl
# SM1141 (slice D of SM1134): a template can ask whether the visitor's address is on
# a named list - and only that. `[% visitor.in_list('office') %]` is true or false;
# `[% visitor.in_any(['a','b']) %]` is true when any is. What it holds:
#   - behind a trusted proxy the answer is about the visitor, not the proxy; a caller
#     who sends their own X-Forwarded-For cannot choose it (the rightmost hop wins)
#   - a page that asks is rendered per request: never written to the shared cache,
#     sent `Cache-Control: no-store, private`, so a second request from another
#     address gets its own answer (the SM1068 viewer-dependent rule)
#   - a page that does NOT ask is cached as before
#   - the address is in no variable, however the page is written: not in the
#     rendered output, and `visitor` carries methods only
#   - a list that is not in the store is false, and a faulted store is false
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_minimal_site run_processor site_tempdir);

my $d = site_tempdir();
setup_minimal_site($d);
make_path("$d/lazysite/auth");
open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "trusted_proxies: 10.0.0.0/8\n";
close $cf;
open my $sf, '>', "$d/lazysite/auth/address-lists.json" or die $!;
print {$sf} encode_json( {
        office => { kind => 'allow', entries => [ { cidr => '203.0.113.0/24', note => '' } ] },
        branch => { kind => 'allow', entries => [ { cidr => '198.51.100.0/24', note => '' } ] },
} );
close $sf;

sub page {
    my ( $name, $body ) = @_;
    open my $p, '>', "$d/$name.md" or die $!;
    print {$p} "---\ntitle: T\n---\n\n$body\n";
    close $p;
}

page( 'where', "IN:[% IF visitor.in_list('office') %]yes[% ELSE %]no[% END %]:END" );
page( 'any',   "ANY:[% IF visitor.in_any(['nope','branch']) %]yes[% ELSE %]no[% END %]:END" );
page( 'gone',  "GONE:[% IF visitor.in_list('missing') %]yes[% ELSE %]no[% END %]:END" );
page( 'plain', "PLAIN:no address asked here" );

sub via {
    my ( $uri, $visitor ) = @_;
    return run_processor( $d, $uri, REMOTE_ADDR => '10.0.0.1', HTTP_X_FORWARDED_FOR => "$visitor, 10.0.0.1" );
}

like( via( '/where', '203.0.113.9' ), qr/IN:\s*yes:END/, 'an address on the list: true' );
unlike( -f "$d/where.html" ? 'cached' : '', qr/cached/, 'the page that asked is not in the shared cache' );
like( via( '/where', '192.0.2.4' ), qr/IN:\s*no:END/, 'a second request from another address gets its own answer' );
ok( !-f "$d/where.html", '...and still nothing is cached' );

my $o = via( '/where', '203.0.113.9' );
like( $o, qr/^Cache-Control:\s*no-store, private/mi, 'sent no-store, private' );
unlike( $o, qr/203\.0\.113\.9|192\.0\.2\.4/, 'the address is not in the page' );

# A caller's own header cannot name them onto the list: the proxy's hop wins.
my $forged = run_processor( $d, '/where', REMOTE_ADDR => '10.0.0.1',
    HTTP_X_FORWARDED_FOR => '203.0.113.9, 192.0.2.77' );
like( $forged, qr/IN:\s*no:END/, 'a forged first hop does not put a caller on the list' );

# Served direct, the header is not read at all.
my $direct = run_processor( $d, '/where', REMOTE_ADDR => '192.0.2.8', HTTP_X_FORWARDED_FOR => '203.0.113.9' );
like( $direct, qr/IN:\s*no:END/, 'a peer that is not a trusted proxy cannot name itself' );

like( via( '/any', '198.51.100.3' ), qr/ANY:\s*yes:END/, 'in_any: true when one of the lists holds the address' );
like( via( '/any', '192.0.2.4' ),    qr/ANY:\s*no:END/,  'in_any: false when none does' );
ok( !-f "$d/any.html", 'in_any is per request too' );

like( via( '/gone', '203.0.113.9' ), qr/GONE:\s*no:END/, 'a list that is not in the store is false' );

# The address is in no variable: the method object is all there is of `visitor`.
page( 'dump', "KEYS:[% FOREACH k IN visitor.keys.sort %][% k %],[% END %]:END VAL:[% visitor.address %][% visitor.ip %][% visitor.client_ip %]:END" );
my $dump = via( '/dump', '203.0.113.9' );
like( $dump, qr/KEYS:\s*in_any,in_list,:END/, 'visitor carries the two methods and nothing else' );
like( $dump, qr/VAL:\s*:END/, 'and there is no address on it under any name' );
unlike( $dump, qr/203\.0\.113\.9/, 'the address never reaches the page' );

# A page that does not ask is cached as it always was.
via( '/plain', '203.0.113.9' );
ok( -f "$d/plain.html", 'a page that does not ask the address is cached' );

# A faulted store answers false (the rule layer denies; the template just cannot say yes).
open my $bad, '>', "$d/lazysite/auth/address-lists.json" or die $!;
print {$bad} "{ not json";
close $bad;
like( via( '/where', '203.0.113.9' ), qr/IN:\s*no:END/, 'a store that will not decode: false' );

done_testing();
