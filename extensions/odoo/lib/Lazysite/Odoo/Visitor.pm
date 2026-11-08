package Lazysite::Odoo::Visitor;

# SM747 CU / Q1 (ruled 2026-10-12): WHO AN ANONYMOUS VISITOR IS, FOR AN ODOO
# BINDING - and why they can only ever reach their own basket.
#
# The ruling's use case is a basket: a visitor adds to it and Odoo holds it as
# a quotation. Several visitors share one connection user, so Odoo cannot tell
# them apart; lazysite has to, and has to do it without trusting anything the
# visitor sends.
#
# SM1369 X5 (H-4): THE MECHANISM IS CORE'S NOW - Lazysite::Endpoint, the request
# kit every extension endpoint uses: the key minted from /dev/urandom and never
# accepted from outside, the cookie signed with this extension's own secret
# (lazysite/odoo/visitor.secret, as before), HttpOnly and SameSite=Strict, the
# CSRF token bound to the key, and a hash of the key in every record. This
# module keeps the names the engine, the endpoint and the tests call, for the
# Odoo extension's id; the cookie, the secret file and every signature are the
# ones it always made, so a visitor key minted before the move still verifies.
use strict;
use warnings;
use Lazysite::Endpoint ();

our $DOCROOT = '';
our $COOKIE  = 'lzs_odoo_visitor';
our $MAX_AGE = 30 * 86400;    # as the kit's $VISITOR_MAX_AGE

my $ID = 'odoo';

# The extension's secret, for the signed cookies that share it (the Odoo session
# cookie and the identity cookie sign under labels of their own). undef when it
# cannot be read or made.
sub secret     { return Lazysite::Endpoint::visitor_secret( $DOCROOT, $ID ) }
sub random_hex { return Lazysite::Endpoint::random_hex(@_) }

# ( key, cookie ), or () when no CSPRNG or no secret.
sub mint { return Lazysite::Endpoint::visitor_mint( $DOCROOT, $ID ) }

sub key_from_cookie {
    my ($header) = @_;
    return Lazysite::Endpoint::visitor_key( $DOCROOT, $ID, $header, $COOKIE );
}

sub visitor_id { return Lazysite::Endpoint::visitor_id(@_) }

sub csrf_token {
    my ($key) = @_;
    return Lazysite::Endpoint::visitor_token( $DOCROOT, $ID, $key );
}

sub verify_csrf {
    my ( $token, $key ) = @_;
    return Lazysite::Endpoint::verify_visitor_token( $DOCROOT, $ID, $token, $key );
}

sub set_cookie_header {
    my ( $cookie, %o ) = @_;
    return Lazysite::Endpoint::visitor_cookie_header( $ID, $cookie, %o, name => $COOKIE );
}

1;
