package Odoo::Transport::Session;

use v5.36;
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use Odoo::Error;
use Odoo::Transport;

our $VERSION = '0.09';

=head1 NAME

Odoo::Transport::Session - Odoo's web session: authenticate once, carry a session id

=head1 SYNOPSIS

    my $t = Odoo::Transport::Session->new( url => 'https://erp.example' );
    my $identity = $t->authenticate( $db, $login, $password );   # once
    my $sid = $t->session_id;        # opaque; the caller carries it

    # later, elsewhere: resume from the carried value
    my $t2 = Odoo::Transport::Session->new( url => ..., session => $sid );
    my $odoo = Odoo::Client->new( url => ..., db => ..., transport => $t2 );
    $odoo->model('res.partner')->search_read(...);   # as that user
    $t2->destroy;                                     # sign out at Odoo

=head1 DESCRIPTION

The third transport. Where JSON-RPC and XML-RPC authenticate every
call with a login and key (C<common.authenticate> + C<execute_kw>),
this one exchanges a login and password once for Odoo's web session
(C</web/session/authenticate>) and carries the session id, making its
calls through C</web/dataset/call_kw>. Every call is attributed in
Odoo to that user.

It presents the same surface as the other transports: C<call('object',
'execute_kw', $db, $uid, $key, $model, $method, \@args, \%kwargs)>, so
L<Odoo::Client>, L<Odoo::Ops::Guard>, scopes, plans, journals and
audit run unchanged over it. The db, uid and key positions are ignored
(the session says who is calling). C<call('common', 'version')> asks
C</web/webclient/version_info>; C<call('common', 'authenticate')>
answers the session's uid without a round trip.

Nothing is persisted: the session id is returned to the caller, who
carries it (a cookie, a memory) and hands it back with C<session>.

Faults keep their categories: an expired or destroyed session dies as
a fault of category C<session>; a refused login as C<credential>.
Neither is a transport failure, so neither is retried.

Odoo refuses a password login over C</web/session/authenticate> for a
user with two-factor authentication; such users cannot use this
transport. Whether a series accepts an API key in place of the
password is a live question per series (TEST-PLAN), not assumed here.

=cut

sub new ($class, %args) {
    my $url = $args{url}
        or Odoo::Error->throw( kind => 'config', message => 'url required' );
    $url =~ s{/+\z}{};
    return bless {
        url      => $url,
        id       => 0,
        json     => JSON::PP->new->utf8->canonical->boolean_values( 0, 1 ),
        http     => $args{http} // Odoo::Transport::http_client(
            timeout            => $args{timeout},
            max_response_bytes => $args{max_response_bytes},
            ssl_ca_file        => $args{ssl_ca_file},
            ssl_verify         => $args{ssl_verify},
        ),
        session  => $args{session},
        identity => undef,
    }, $class;
}

sub name       ($self) { 'session' }
sub session_id ($self) { $self->{session} }
sub http       ($self) { $self->{http} }

=head2 identity

What authentication told us about the user, normalised across series:
C<uid>, C<login>, C<name>, C<lang>, C<tz>, C<company_id>,
C<company_ids> (allowed companies), C<is_admin>, C<is_system>,
C<partner_id>, C<db>, plus C<raw> (the server's whole answer). Set by
C<authenticate>; for a resumed session, filled on the first
C<common.authenticate> (which asks C</web/session/get_session_info>).

=cut

sub identity ($self) { $self->{identity} }

=head2 authenticate($db, $login, $password)

One round trip to C</web/session/authenticate>. Returns the identity;
C<session_id> holds the value to carry. Dies with fault category
C<credential> when refused.

=cut

sub authenticate ($self, $db, $login, $password) {
    my ( $result, $res ) = $self->_rpc( '/web/session/authenticate',
        { db => $db, login => $login, password => $password }, 'session.authenticate' );
    my $sid = _cookie( $res, 'session_id' );
    Odoo::Error->throw(
        kind        => 'fault',
        message     => 'authentication did not establish a session',
        fault_class => 'odoo.exceptions.AccessDenied',
    ) if !defined $sid || !ref $result || !$result->{uid};
    $self->{session}  = $sid;
    $self->{identity} = _identity( $result, $db );
    return $self->{identity};
}

=head2 destroy

C</web/session/destroy>: ends the session at Odoo. Idempotent; the
object forgets the session either way.

=cut

sub destroy ($self) {
    return 1 if !defined $self->{session};
    eval { $self->_rpc( '/web/session/destroy', {}, 'session.destroy' ) };
    my $err = $@;
    $self->{session}  = undef;
    $self->{identity} = undef;
    die $err if $err && !( ref $err && $err->isa('Odoo::Error') && $err->is_session_expired );
    return 1;
}

sub call ($self, $service, $method, @params) {
    if ( $service eq 'object' && $method eq 'execute_kw' ) {
        my ( undef, undef, undef, $model, $mmethod, $args, $kwargs ) = @params;
        $self->_need_session("$model.$mmethod");
        my ($result) = $self->_rpc(
            "/web/dataset/call_kw/$model/$mmethod",
            { model => $model, method => $mmethod, args => $args // [], kwargs => $kwargs // {} },
            "call_kw $model.$mmethod",
        );
        return $result;
    }
    if ( $service eq 'common' && $method eq 'version' ) {
        my ($result) = $self->_rpc( '/web/webclient/version_info', {}, 'version_info' );
        return $result;
    }
    if ( $service eq 'common' && $method eq 'authenticate' ) {
        $self->_need_session('authenticate');
        if ( !$self->{identity} ) {
            my ($info) = $self->_rpc( '/web/session/get_session_info', {}, 'session.get_session_info' );
            $self->{identity} = _identity( $info, $params[0] );
        }
        return $self->{identity}{uid};
    }
    Odoo::Error->throw(
        kind    => 'usage',
        message => "the session transport does not carry $service.$method",
    );
}

# --- internals --------------------------------------------------------------

sub _need_session ($self, $what) {
    Odoo::Error->throw(
        kind        => 'fault',
        message     => "no session: authenticate first ($what)",
        fault_class => 'odoo.http.SessionExpiredException',
    ) if !defined $self->{session};
}

# one JSON-RPC post to a web route; returns (result, raw response)
sub _rpc ($self, $path, $params, $label) {
    my $body = $self->{json}->encode( { jsonrpc => '2.0', method => 'call', params => $params, id => ++$self->{id} } );
    my %headers = ( 'content-type' => 'application/json' );
    $headers{cookie} = "session_id=$self->{session}" if defined $self->{session};
    my $res = $self->{http}->post( "$self->{url}$path", { content => $body, headers => \%headers } );
    Odoo::Transport::refuse_by_policy( $res, $label );
    if ( !$res->{success} ) {
        my $detail = ( $res->{status} // 0 ) == 599
            ? ( $res->{content} // 'internal HTTP::Tiny error' )
            : "HTTP $res->{status} $res->{reason}";
        Odoo::Error->throw( kind => 'transport', message => "$label: $detail" );
    }
    my $data = eval { $self->{json}->decode( $res->{content} ) };
    if ( !$data || ref $data ne 'HASH' ) {
        my $peek = substr( $res->{content} // '', 0, 120 );
        Odoo::Error->throw( kind => 'transport', message => "$label: unparseable response: $peek" );
    }
    if ( my $err = $data->{error} ) {
        my $msg = $err->{message} // 'unknown fault';
        my $class;
        if ( ref $err->{data} eq 'HASH' ) {
            $msg .= ': ' . $err->{data}{message} if defined $err->{data}{message};
            $class = $err->{data}{name};
        }
        # a session that Odoo no longer knows forgets itself here
        $self->{session} = $self->{identity} = undef
            if ( $class // '' ) eq 'odoo.http.SessionExpiredException';
        Odoo::Error->throw( kind => 'fault', message => $msg, code => $err->{code}, fault_class => $class );
    }
    return ( $data->{result}, $res );
}

# the value of one cookie from a response's set-cookie header(s)
sub _cookie ($res, $name) {
    my $h = $res->{headers}{'set-cookie'} // return undef;
    for my $line ( ref $h eq 'ARRAY' ? @$h : ($h) ) {
        return $1 if $line =~ /(?:^|;\s*)\Q$name\E=([^;]*)/;
    }
    return undef;
}

# session_info -> one shape across series
sub _identity ($info, $db) {
    my $ctx  = ref $info->{user_context} eq 'HASH' ? $info->{user_context} : {};
    my $comp = ref $info->{user_companies} eq 'HASH' ? $info->{user_companies} : {};
    my $current = $comp->{current_company};
    $current = $current->[0] if ref $current eq 'ARRAY';
    my @allowed;
    if ( ref $comp->{allowed_companies} eq 'HASH' ) { @allowed = sort { $a <=> $b } map { 0 + $_ } keys %{ $comp->{allowed_companies} } }
    elsif ( ref $comp->{allowed_companies} eq 'ARRAY' ) { @allowed = map { ref $_ ? $_->[0] : $_ } @{ $comp->{allowed_companies} } }
    return {
        uid         => $info->{uid},
        login       => $info->{username},
        name        => $info->{name},
        lang        => $ctx->{lang},
        tz          => $ctx->{tz},
        company_id  => $current // $info->{company_id},
        company_ids => \@allowed,
        is_admin    => $info->{is_admin} ? 1 : 0,
        is_system   => $info->{is_system} ? 1 : 0,
        partner_id  => $info->{partner_id},
        db          => $info->{db} // $db,
        raw         => $info,
    };
}

1;
