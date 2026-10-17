package Odoo::Transport::Session;

use v5.36;
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use Odoo::Error;
use Odoo::Transport;

our $VERSION = '0.24';

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

Cookies: every cookie any response sets (the session id, and what a proxy
or balancer in front of Odoo adds, such as a sticky-session cookie) is kept
and sent back on every request, so the RPC calls and C<get> of a web route
stay on the host that holds the session. A new C<authenticate> starts from
no cookies. C<get> answers a route's raw response (a report is a route, not
an RPC call); C<set_reauth> lets a holder with the password have an expired
session opened again once.

Odoo refuses a password login over C</web/session/authenticate> for a
user with two-factor authentication; such users cannot use this
transport. Whether a series accepts an API key in place of the
password is a live question per series (TEST-PLAN), not assumed here.

=cut

sub new ($class, %args) {
    my $url = $args{url}
        or Odoo::Error->throw( kind => 'config', message => 'url required' );
    $url =~ s{/+\z}{};
    my $self = bless {
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
        cookies  => {},
    }, $class;
    $self->{cookies}{session_id} = $self->{session} if defined $self->{session};
    return $self;
}

sub name       ($self) { 'session' }

=head2 set_reauth($code)

A coderef that opens the session anew (it calls C<authenticate>), for a
holder that has the login and the password. A C<call> that meets an expired
or forgotten session runs it once and sends the call again: Odoo refuses
such a call before it runs the method, so nothing is done twice. Without
one, an expired session dies as category C<session>.

=cut

sub set_reauth ($self, $code) { $self->{reauth} = $code; return $self }
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
C<credential> when refused. When Odoo accepts the login and opens no
session (a user with two-factor authentication) it dies with fault
category C<second_factor>: C<< $err->is_no_session >>.

=cut

sub authenticate ($self, $db, $login, $password) {
    # a fresh login starts from no cookies: a sticky cookie of an earlier
    # (lost) session must not pin this one to the host that lost it
    $self->{cookies} = {};
    $self->{session} = undef;
    my ( $result, $res ) = eval { $self->_rpc( '/web/session/authenticate',
        { db => $db, login => $login, password => $password }, 'session.authenticate' ) };
    if ( my $err = $@ ) {
        # Odoo hands an anonymous session cookie even to a refused login
        $self->{session} = undef;
        delete $self->{cookies}{session_id};
        die $err;
    }
    my $sid = _cookie( $res, 'session_id' );
    if ( !defined $sid || !ref $result || !$result->{uid} ) {
        $self->{session} = undef;
        delete $self->{cookies}{session_id};
        Odoo::Error->throw(
            kind        => 'fault',
            message     => 'authentication did not establish a session',
            fault_class => 'oom.NoSession',
        );
    }
    $self->{session}  = $sid;
    $self->{cookies}{session_id} = $sid;
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
    delete $self->{cookies}{session_id};
    die $err if $err && !( ref $err && $err->isa('Odoo::Error') && $err->is_session_expired );
    return 1;
}

sub call ($self, $service, $method, @params) {
    if ( $service eq 'object' && $method eq 'execute_kw' ) {
        my ( undef, undef, undef, $model, $mmethod, $args, $kwargs ) = @params;
        my $once = sub {
            $self->_need_session("$model.$mmethod");
            my ($result) = $self->_rpc(
                "/web/dataset/call_kw/$model/$mmethod",
                { model => $model, method => $mmethod, args => $args // [], kwargs => $kwargs // {} },
                "call_kw $model.$mmethod",
            );
            return $result;
        };
        my @r = eval { $once->() };
        my $err = $@;
        # Odoo refuses a call whose session it no longer knows before it runs
        # the method, so a call that met that may be sent again once the
        # session is opened anew; only when the holder gave a way to do so
        if ( $err && $self->{reauth} && !$self->{reauthing}
            && ref $err && $err->isa('Odoo::Error') && $err->is_session_expired ) {
            local $self->{reauthing} = 1;
            $self->{reauth}->();
            return $once->();
        }
        die $err if $err;
        return $r[0];
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

=head2 get($path, %opts)

A GET of C<$path> (a route under the server's URL, such as
C</report/pdf/sale.report_saleorder/12>) with every cookie held, answering
the raw response C<< { status, headers, content, ... } >> without
interpreting it: a login redirect or an HTML page is the caller's to
recognise. Cookies the answer sets are kept. A response over
C<max_response_bytes> still dies as kind C<refused>. C<timeout> (seconds)
applies to this request only.

=cut

sub get ($self, $path, %opts) {
    my %headers;
    my $cookie = $self->_cookie_header;
    $headers{cookie} = $cookie if length $cookie;
    my $http = $self->{http};
    my $was  = $http->can('timeout') ? $http->timeout : undef;
    $http->timeout( $opts{timeout} ) if defined $opts{timeout} && $http->can('timeout');
    my $res = eval { $http->get( "$self->{url}$path", { headers => \%headers } ) };
    my $err = $@;
    $http->timeout($was) if defined $was && defined $opts{timeout};
    die $err if $err;
    $self->_absorb_cookies($res);
    my $status = $res->{status} // 0;
    Odoo::Error->throw( kind => 'refused', code => 'oversize', message => "$path: response over the configured size cap" )
        if $status == 599 && ( $res->{content} // '' ) =~ /exceeds the maximum allowed/;
    return $res;
}

=head2 post_form($path, \%fields, %opts)

A form POST (C<application/x-www-form-urlencoded>) to a route under the
server's URL, with every cookie held, answering the raw response as C<get>
does and keeping the cookies it sets. It is how a public page's form is
submitted as a browser would (the password-reset page); no redirect is
followed, so a 303 is the caller's to read.

=cut

sub post_form ($self, $path, $fields, %opts) {
    my %headers;
    my $cookie = $self->_cookie_header;
    $headers{cookie} = $cookie if length $cookie;
    my $http = $self->{http};
    my $was  = $http->can('timeout') ? $http->timeout : undef;
    $http->timeout( $opts{timeout} ) if defined $opts{timeout} && $http->can('timeout');
    my $res = eval { $http->post_form( "$self->{url}$path", $fields, { headers => \%headers } ) };
    my $err = $@;
    $http->timeout($was) if defined $was && defined $opts{timeout};
    die $err if $err;
    $self->_absorb_cookies($res);
    my $status = $res->{status} // 0;
    Odoo::Error->throw( kind => 'refused', code => 'oversize', message => "$path: response over the configured size cap" )
        if $status == 599 && ( $res->{content} // '' ) =~ /exceeds the maximum allowed/;
    return $res;
}

=head2 cookies

The names of the cookies held (never the values): C<session_id> and
whatever the server or a proxy in front of it set, such as a balancer's
sticky cookie. Every one is sent back on every request, so calls and
route fetches stay on the host that holds the session.

=cut

sub cookies ($self) { [ sort keys %{ $self->{cookies} } ] }

=head2 has_session

True when a session id is held.

=cut

sub has_session ($self) { defined $self->{session} }

# --- internals --------------------------------------------------------------

sub _cookie_header ($self) {
    my $c = $self->{cookies};
    return join '; ', map { "$_=$c->{$_}" } sort { $a eq 'session_id' ? -1 : $b eq 'session_id' ? 1 : $a cmp $b } keys %$c;
}

# keep every cookie a response sets; an empty value or an expiry in the
# past (Max-Age <= 0) removes it
sub _absorb_cookies ($self, $res) {
    my $h = $res->{headers}{'set-cookie'} // return;
    for my $line ( ref $h eq 'ARRAY' ? @$h : ($h) ) {
        my ( $first, @attrs ) = split /;\s*/, $line;
        my ( $name, $value ) = $first =~ /^\s*([^=\s]+)=(.*)\z/ or next;
        my ($age) = map { /^max-age=(-?\d+)/i ? $1 : () } @attrs;
        if ( $value eq '' || ( defined $age && $age <= 0 ) ) {
            delete $self->{cookies}{$name};
            $self->{session} = undef if $name eq 'session_id';
            next;
        }
        $self->{cookies}{$name} = $value;
        $self->{session} = $value if $name eq 'session_id';
    }
    return;
}

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
    my $cookie = $self->_cookie_header;
    $headers{cookie} = $cookie if length $cookie;
    my $res = $self->{http}->post( "$self->{url}$path", { content => $body, headers => \%headers } );
    $self->_absorb_cookies($res);
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
        if ( ( $class // '' ) eq 'odoo.http.SessionExpiredException' ) {
            $self->{session} = $self->{identity} = undef;
            delete $self->{cookies}{session_id};
        }
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
