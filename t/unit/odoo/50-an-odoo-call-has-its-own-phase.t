#!/usr/bin/perl
# SM1144 (SM1082 T0): THE ODOO ENDPOINT NAMES THE TIME IT SPENT IN ODOO.
#
# The sites agent's 2026-10-17 measurement put an Odoo read at about 550 ms, of
# which about 200 ms is lazysite starting two programs and 50-90 ms is Odoo. A
# Server-Timing header that says `call` apart from `load` and `identity` is what
# lets that be read off a response instead of inferred from three scripts. The
# endpoint's `?csrf=1` makes no Odoo call; a binding read does, and a request that
# made none must not claim one.
#
# Driven in-process, as t/integration/170 is, because the transport is OOM's fake
# Odoo and a child process would not have it. No network.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use OdooTest   qw(oom_or_skip shop_ready bind quiet);

BEGIN { oom_or_skip() }

my $root = repo_root();
require "$root/lazysite-odoo.pl";

my ( $d, $fake ) = shop_ready();
bind( $d, id => 'list', operation => 'shop.products', modes => 'public', params => 'n=limit' );
open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "server_timing: on\n";
close $cf;

sub hit {
    my ($qs) = @_;
    my $out = '';
    {
        local %ENV = (
            PATH           => $ENV{PATH},
            DOCUMENT_ROOT  => $d,
            REQUEST_METHOD => 'GET',
            QUERY_STRING   => $qs,
            CONTENT_LENGTH => 0,
            REMOTE_ADDR    => '203.0.113.5',
        );
        local *STDOUT;
        open STDOUT, '>', \$out or die $!;
        quiet( sub { main::main() } );
    }
    my ($st) = $out =~ /Status:\s*(\d+)/;
    my ($tm) = $out =~ /^Server-Timing:\s*(.*?)\r?$/m;
    # SM1164: the call phase carries a description, `call;desc="in-process";dur=...`.
    my @names = defined $tm ? ( $tm =~ /([a-z]+);(?:desc="[^"]*";)?dur=/g ) : ();
    return ( $st, \@names );
}

my ( $st, $names ) = hit('binding=list');
is( $st, 200, 'a binding read is answered' );
ok( ( grep { $_ eq 'call' } @$names ), 'and its Server-Timing names the Odoo call' )
    or diag( join ',', @$names );
is_deeply( [ grep { /\A(?:config|identity|render|call)\z/ } @$names ], [qw(config identity render call)],
    '...after the config, identity and render that led to it' );

( $st, $names ) = hit('csrf=1');
is( $st, 200, 'the token request is answered' );
ok( !( grep { $_ eq 'call' } @$names ), '...and made no Odoo call, so has no call phase' );

done_testing;
