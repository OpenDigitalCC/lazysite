package Odoo::Ops::Route;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Scalar::Util qw(blessed);

use Odoo::Error;

=head1 NAME

Odoo::Ops::Route - one call of a JSON web route of Odoo, as the login

=head1 SYNOPSIS

    my $answer = Odoo::Ops::Route->send( $client, '/discuss/channel/mark_as_read', { channel_id => 7, last_message_id => 120 } );

=head1 DESCRIPTION

Some of what Odoo's own client does is a web route, not a model method: the
method behind it is private (Odoo refuses a private method over RPC) or its
record rule refuses a plain write. A C<route> change of a plan
(L<Odoo::Ops::Plan>) is applied by L<Odoo::Ops::Runner> through this module,
after the guard has held the path to the routes the operation declared
(C<routes> of L<Odoo::Ops::Operation>).

A client on a web session (a C<credential = password> config, or a session id
carried by the caller) uses that session. Any other client opens one from its
own login and secret, which works where the secret is the login's password (the
local cluster's configs); a real API key is refused by Odoo's web login, and the
call dies as C<config> naming that and the fix.

=head2 send($client, $path, \%params)

The route's answer. Odoo's own fault comes back as it came.

=head2 session($client, $what)

C<< ( $web, $own ) >>: the web session to use and whether this call opened it
(and must C<destroy> it). C<$what> names the action in the C<config> error.

=cut

sub send ($class, $client, $path, $params = {}) {
    my ( $web, $own ) = $class->session( $client, "the route $path" );
    my $res = eval { $web->route( $path, $params ) };
    my $err = $@;
    eval { $web->destroy } if $own;
    die $err if $err;
    return $res;
}

sub session ($class, $client, $what) {
    my $t = $client->transport;
    while ( blessed($t) ) {
        return ( $t, 0 ) if $t->can('route') && $t->can('session_id') && defined $t->session_id;
        last if !$t->can('inner_transport');
        $t = $t->inner_transport;
    }
    my $web = eval { $client->own_web_session };
    if ( !$web ) {
        my $e = $@;
        my $why = blessed($e) && $e->can('message') ? ( $e->message =~ s/\s+/ /gr ) : "$e";
        Odoo::Error->throw(
            kind    => 'config',
            message => "$what needs a web session as the login, and none could be opened: $why",
            fix     => 'use a config with credential = password (a session as the login), or a login whose key is its password',
        );
    }
    return ( $web, 1 );
}

1;
