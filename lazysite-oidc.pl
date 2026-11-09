#!/usr/bin/perl

# SM1351: THE OPENID CONNECT SIGN-IN ENDPOINT - the OIDC extension's own.
#
#   GET ?provider=NAME&next=/path   start: a state, a nonce and a PKCE verifier are
#                                   made and recorded, the state cookie set, and the
#                                   browser sent to the provider
#   GET ?code=...&state=...         the provider's answer: the state checked against
#                                   the cookie, the code exchanged at the token
#                                   endpoint with the client's secret, the ID token's
#                                   claims checked (ruling 185), the groups mapped,
#                                   and a session minted by core (H-1); then on to
#                                   `next`
#
# It takes no body: every request is a GET, and the kit (Lazysite::Endpoint, H-4)
# refuses any body unread and any POST before this extension's code runs. What
# signs a person in is core's (mint_provider_session) and the extension's engine
# (Lazysite::Ext::OIDC); this file reads the request and writes the answer.

use strict;
use warnings;

BEGIN {
    require Cwd;
    require File::Basename;
    # SM1078: then the docroot's ../lib, where install.pl puts it whatever
    # --cgibin was (one rule in every script a cgi-bin runs, t/lint/263).
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    my $doc = $ENV{DOCUMENT_ROOT} || $ENV{REDIRECT_DOCUMENT_ROOT} || '';
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib", ( length $doc ? "$doc/../lib" : () ) ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
    # SM1369 X1: the extension's own module is in its payload lib, beside the
    # descriptor in the extensions/ next to that lib.
    require Lazysite::Extensions;
    my $root = Lazysite::Extensions::engine_root();
    Lazysite::Extensions::add_payload_lib( Lazysite::Extensions::extensions_dir($root) . '/oidc.pl' )
        if defined $root;
}

exit main() if !caller;

our @EXTRA;

sub _html {
    my ($s) = @_;
    $s //= '';
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    return $s;
}

sub reply {
    my ( $status, $message ) = @_;
    my $body = "<!doctype html>\n<html><head><meta charset=\"utf-8\"><title>Sign in</title></head><body>\n"
        . '<p>' . _html($message) . "</p>\n<p><a href=\"/login\">Back to sign in</a></p>\n</body></html>\n";
    binmode STDOUT;
    print "Status: $status\r\n";
    print "Content-Type: text/html; charset=utf-8\r\n";
    print "Cache-Control: no-store\r\n";
    print "$_\r\n" for @EXTRA;
    print 'Content-Length: ' . length($body) . "\r\n\r\n";
    print $body;
    return 0;
}

sub redirect {
    my ($to) = @_;
    binmode STDOUT;
    print "Status: 302 Found\r\n";
    print "Location: $to\r\n";
    print "Cache-Control: no-store\r\n";
    print "$_\r\n" for @EXTRA;
    print "Content-Length: 0\r\n\r\n";
    return 0;
}

sub _query {
    my %q;
    for my $pair ( split /&/, ( $ENV{QUERY_STRING} // '' ) ) {
        my ( $k, $v ) = split /=/, $pair, 2;
        next unless defined $k && length $k;
        for ( $k, $v ) {
            next unless defined;
            tr/+/ /;
            s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
        }
        $q{$k} = $v // '';
    }
    return \%q;
}

sub _cookie {
    my ($name) = @_;
    my ($v) = ( $ENV{HTTP_COOKIE} // '' ) =~ /(?:\A|;\s*)\Q$name\E=([0-9a-f]{64})(?:;|\z)/;
    return $v;
}

sub _ip {
    my ($lz) = @_;
    require Lazysite::Util;
    return Lazysite::Util::request_address( Lazysite::Util::trusted_proxy_spec($lz) ) // '';
}

sub main {
    local @EXTRA = ();
    my $docroot = $ENV{DOCUMENT_ROOT} // '';
    return reply( '500 Internal Server Error', 'This site has no document root.' )
        unless length $docroot && -d $docroot;

    # H-4: the kit reads the body - none is taken - and checks any POST's token
    # before anything of this extension runs. A POST is then refused: the
    # endpoint answers GETs only.
    require Lazysite::Endpoint;
    my ( undef, $too ) = Lazysite::Endpoint::read_body( $ENV{CONTENT_LENGTH}, 0 );
    return reply( $too->[0], 'This endpoint takes no body.' ) if $too;
    my $method = $ENV{REQUEST_METHOD} // 'GET';
    if ( $method ne 'GET' ) {
        my $g = Lazysite::Endpoint::post_guard( docroot => $docroot, id => 'oidc', req => {} );
        return reply( $g ? $g->[0] : '405 Method Not Allowed', 'This endpoint takes GET only.' );
    }

    require Lazysite::Manager::Extensions;
    require Lazysite::Paths;
    no warnings 'once';
    local $Lazysite::Manager::Extensions::DOCROOT = $docroot;
    return reply( '404 Not Found', 'This sign-in is not offered here.' )
        unless Lazysite::Manager::Extensions::extension_enabled('extensions/oidc.pl');
    my $lz = Lazysite::Paths::lazysite_dir($docroot);

    require Lazysite::Ext::OIDC;
    require Lazysite::Util;
    my $q      = _query();
    my $secure = $ENV{HTTPS} ? 1 : 0;

    if ( defined $q->{provider} ) {
        my $host = Lazysite::Util::request_host();
        return reply( '400 Bad Request', 'This request names no host.' ) unless length $host;
        my $port = ( $ENV{HTTP_HOST} // '' ) =~ /:(\d+)\z/ ? ":$1" : '';
        my $r = Lazysite::Ext::OIDC::start( docroot => $docroot, lz => $lz, name => $q->{provider},
            next => Lazysite::Util::sanitise_next( $q->{next} ), base => ( $secure ? 'https' : 'http' ) . "://$host$port",
            secure => $secure,                                   ip => _ip($lz) );
        return reply( $r->{status}, $r->{error} ) unless $r->{ok};
        push @EXTRA, $r->{cookie};
        return redirect( $r->{location} );
    }

    if ( defined $q->{state} ) {
        push @EXTRA, Lazysite::Ext::OIDC::clear_state_cookie( secure => $secure );
        my $r = Lazysite::Ext::OIDC::callback( docroot => $docroot, lz => $lz, query => $q,
            cookie => _cookie( Lazysite::Ext::OIDC::state_cookie_name() ), ip => _ip($lz),
            ua     => substr( $ENV{HTTP_USER_AGENT} // '', 0, 120 ) );
        return reply( $r->{status}, $r->{error} ) unless $r->{ok};
        require Lazysite::Auth::Session;
        push @EXTRA, Lazysite::Auth::Session::session_cookie_headers( $r->{cookie}, secure => $secure, dir => $lz );
        return redirect( Lazysite::Util::sanitise_next( $r->{next} ) );
    }

    return reply( '400 Bad Request', 'Choose a way to sign in on the sign-in page.' );
}

1;
