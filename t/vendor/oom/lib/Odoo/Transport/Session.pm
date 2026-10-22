package Odoo::Transport::Session;

use v5.36;
use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use Odoo::JSON ();
use Odoo::Error;
use Odoo::Transport;

our $VERSION = '0.42';

use constant TRUSTED_DEVICE_COOKIE => 'td_id';
 use constant DEVICE_AGENT => 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36 odoo-oom-perl';

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
a fault of category C<session>; a refused login as C<credential>; a
call while a sign-in waits for the authenticator code as
C<second-factor-required>; a refused code as C<second-factor>. None is a
transport failure, so none is retried.

Cookies: every cookie any response sets (the session id, and what a proxy
or balancer in front of Odoo adds, such as a sticky-session cookie) is kept
and sent back on every request, so the RPC calls and C<get> of a web route
stay on the host that holds the session. A new C<authenticate> starts from
no cookies. C<get> answers a route's raw response (a report is a route, not
an RPC call); C<set_reauth> lets a holder with the password have an expired
session opened again once.

A user with Odoo's two-factor authentication (C<auth_totp>) is signed in in two
steps: C<authenticate> answers C<< { second_factor => 'totp', pending => 1 } >>
with the half-open session kept, and C<complete_totp> gives the authenticator
code at C</web/login/totp>. Whether a series accepts an API key in place of
the password is a live question per series (TEST-PLAN), not assumed here.

=cut

sub new ($class, %args) {
    my $url = $args{url}
        or Odoo::Error->throw( kind => 'config', message => 'url required' );
    $url =~ s{/+\z}{};
    my $self = bless {
        url      => $url,
        id       => 0,
        json     => Odoo::JSON->new( plain_bools => 1 ),
        http     => $args{http} // Odoo::Transport::http_client(
            timeout            => $args{timeout},
            max_response_bytes => $args{max_response_bytes},
            ssl_ca_file        => $args{ssl_ca_file},
            ssl_verify         => $args{ssl_verify},
        ),
        session  => $args{session},
        identity => $args{identity},
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

=head2 authenticate($db, $login, $password, %opts)

One round trip to C</web/session/authenticate>. Returns the identity;
C<session_id> holds the value to carry. Dies with fault category
C<credential> when refused.

When the password is right and Odoo opens no session because the user has
two-factor authentication, it returns C<< { second_factor => 'totp',
pending => 1 } >> instead, and keeps the half-open session's cookies so
that L</complete_totp> continues it. Until then a call over this transport
dies as category C<second-factor-required>.

C<trusted_device =E<gt> VALUE> (the value L</complete_totp> returned) is sent
as Odoo's trusted-device cookie C<td_id>. Odoo reads it at C</web/login/totp>:
when it still trusts the device it opens the session at once and the
identity is returned as for a user without a second factor; when it does not,
the answer is the pending one again.

=cut

sub authenticate ($self, $db, $login, $password, %opts) {
    # a fresh login starts from no cookies: a sticky cookie of an earlier
    # (lost) session must not pin this one to the host that lost it
    $self->{cookies} = {};
    $self->{session} = undef;
    $self->{pending} = 0;
    $self->{identity} = undef;
    $self->{db} = $db;
    $self->{cookies}{ TRUSTED_DEVICE_COOKIE() } = $opts{trusted_device}
        if defined $opts{trusted_device} && length $opts{trusted_device};
    my ( $result, $res ) = eval { $self->_rpc( '/web/session/authenticate',
        { db => $db, login => $login, password => $password }, 'session.authenticate' ) };
    if ( my $err = $@ ) {
        # Odoo hands an anonymous session cookie even to a refused login
        $self->{session} = undef;
        $self->{cookies} = {};
        die $err;
    }
    my $sid = _cookie( $res, 'session_id' );
    if ( !defined $sid ) {
        $self->{session} = undef;
        $self->{cookies} = {};
        Odoo::Error->throw(
            kind        => 'fault',
            message     => 'authentication did not establish a session',
            fault_class => 'oom.NoSession',
        );
    }
    $self->{session}  = $sid;
    $self->{cookies}{session_id} = $sid;
    if ( !ref $result || !$result->{uid} ) {
        # accepted, and no session: Odoo wants the second factor
        $self->{pending} = 1;
        return $self->_try_trusted_device if exists $self->{cookies}{ TRUSTED_DEVICE_COOKIE() };
        return { second_factor => 'totp', pending => 1 };
    }
    delete $self->{cookies}{ TRUSTED_DEVICE_COOKIE() };
    $self->{identity} = _identity( $result, $db );
    return $self->{identity};
}

=head2 require_signed_in($transport, $identity)

A plain function for a holder that can only use a password session: given what
C<authenticate> answered, it returns the identity, or, when the answer is the
pending sign-in, ends the half-open session at Odoo and dies with fault category
C<second-factor-required>.

=cut

sub require_signed_in ($web, $id) {
    return $id unless $id->{pending};
    eval { $web->destroy };
    Odoo::Error->throw( _second_factor_required() );
}

=head2 pending

True while a sign-in waits for the authenticator code.

=head2 resume_pending(session =E<gt> $sid, ...)

A transport that holds a half-open sign-in (the C<session_id> a caller carried
from the pending C<authenticate>) and can take L</complete_totp>. Called on a
transport it shares that one's server and HTTP client; called on the class it
takes C<url> and the options of C<new>. C<cookies> (a hash of name to value)
restores what a balancer in front of Odoo set. C<db> is optional.

=cut

sub pending ($self) { $self->{pending} ? 1 : 0 }

sub resume_pending ( $self, %args ) {
    my $sid = delete $args{session}
        or Odoo::Error->throw( kind => 'usage', message => 'resume_pending needs the session id of the pending sign-in' );
    my $cookies = delete $args{cookies} // {};
    my $db      = delete $args{db};
    my $t = ref $self
        ? ref($self)->new( url => $self->{url}, http => $self->{http}, %args )
        : $self->new(%args);
    $t->{cookies} = { %$cookies, session_id => $sid };
    $t->{session} = $sid;
    $t->{pending} = 1;
    $t->{db}      = $db;
    return $t;
}

=head2 complete_totp($code, remember =E<gt> 0|1)

Finishes a pending sign-in. It reads the form Odoo serves at
C</web/login/totp> (with its C<csrf_token>), posts C<totp_token> (the code)
and, with C<remember>, C<remember=1> (the checkbox Odoo's own form offers,
"Don't ask again on this device"), then reads the session back at
C</web/session/get_session_info> and returns the identity as
C<authenticate> does for a user without a second factor. With C<remember>
the identity carries C<trusted_device>, C<< { name => 'td_id', value => ... } >>:
Odoo's trusted-device cookie, which the transport does not keep. Odoo names the device after the browser and platform of the request's
User-Agent and fails (HTTP 500, read live on 16) when it cannot place one, so with
C<remember> the code is posted with C<user_agent> (the person's own browser, when
the caller passes it) or, by default, a generic browser agent string. The route and
the field names are the same on 16, 18 and 19.

A wrong code dies as a fault of category C<second-factor>, with Odoo's own
words; the pending sign-in stays open and the caller can ask again. Odoo's
rate limit on codes is Odoo's: nothing here counts tries. A pending sign-in
Odoo no longer knows (it expired, or was never made) dies as category
C<session>, and the transport forgets it.

=cut

sub complete_totp ($self, $code, %opts) {
    Odoo::Error->throw( kind => 'usage', message => 'no sign-in is waiting for an authenticator code' )
        if !$self->{pending};
    Odoo::Error->throw( kind => 'usage', message => 'complete_totp needs the code' )
        if !defined $code || $code !~ /\S/;
    my $form = $self->get('/web/login/totp');
    my $gone = $self->_totp_gone($form);
    return $self->_totp_signed_in( $form, $opts{remember} ) if defined $gone && !$gone;
    $self->_forget_pending if $gone;
    Odoo::Error->throw( _pending_expired() ) if $gone;
    my $csrf = _csrf( $form->{content} );
    Odoo::Error->throw( kind => 'fault', message => 'the two-factor form carries no csrf_token' )
        if !defined $csrf;
    # Odoo names the trusted device after the browser and platform it reads from the
    # User-Agent and fails on a request whose agent it cannot place
    my %agent = $opts{remember} ? ( headers => { 'user-agent' => $opts{user_agent} // DEVICE_AGENT } ) : ();
    my $res = $self->post_form( '/web/login/totp',
        { csrf_token => $csrf, totp_token => $code, ( $opts{remember} ? ( remember => 1 ) : () ) }, %agent );
    my $after = $self->_totp_gone($res);
    if ( defined $after && !$after ) { return $self->_totp_signed_in( $res, $opts{remember} ) }
    if ($after) {
        $self->_forget_pending;
        Odoo::Error->throw( _pending_expired() );
    }
    Odoo::Error->throw(
        kind        => 'fault',
        message     => _form_error( $res->{content} ) // "Odoo did not accept the code (HTTP " . ( $res->{status} // 0 ) . ')',
        fault_class => 'oom.SecondFactor',
    );
}

=head2 destroy

C</web/session/destroy>: ends the session at Odoo. Idempotent; the
object forgets the session either way.

=cut

sub destroy ($self) {
    return 1 if !defined $self->{session};
    eval { $self->_rpc( '/web/session/destroy', {}, 'session.destroy' ) };
    my $err = $@;
    $self->{pending}  = 0;
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
                idempotent => Odoo::Transport::is_read_method($mmethod),
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
            my ($info) = $self->_rpc( '/web/session/get_session_info', {}, 'session.get_session_info', idempotent => 1 );
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
does and keeping the cookies it sets. C<headers> (a hash) adds request headers. It is how a public page's form is
submitted as a browser would (the password-reset page); no redirect is
followed, so a 303 is the caller's to read.

=cut

sub post_form ($self, $path, $fields, %opts) {
    my %headers = %{ $opts{headers} // {} };
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

=head2 route($path, \%params)

One JSON-RPC call to a web route of Odoo that is not C</web/dataset/call_kw>
(a controller such as C</mail/channel/set_last_seen_message>), with the
session's cookies, answering the route's C<result>. Odoo's own fault comes
back as a C<fault> in its words; a session Odoo no longer knows dies as
category C<session>. A route that is not JSON-RPC is C<get> or C<post_form>.

=cut

sub route ($self, $path, $params = {}) {
    $self->_need_session($path);
    my ($result) = $self->_rpc( $path, $params, "route $path" );
    return $result;
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

# the fault of a call or a sign-in that needs the authenticator code
sub _second_factor_required () {
    return (
        kind        => 'fault',
        message     => "this user's sign-in needs the second factor (Odoo's authenticator code)",
        fault_class => 'oom.SecondFactorRequired',
        fix         => 'ask the person for their Odoo authenticator code and complete the sign-in with complete_totp',
    );
}

sub _pending_expired () {
    return (
        kind        => 'fault',
        message     => 'the pending sign-in is no longer known to Odoo (it expired or was never made)',
        fault_class => 'odoo.http.SessionExpiredException',
        fix         => 'sign in again with the login and password',
    );
}

sub _forget_pending ($self) {
    $self->{pending} = 0;
    $self->{session} = undef;
    $self->{cookies} = {};
    return;
}

# Did a /web/login/totp answer say the pending session is gone (1), the
# sign-in is done (0), or is the form still to be filled in (undef)?
sub _totp_gone ($self, $res) {
    my $status = $res->{status} // 0;
    return undef if $status !~ /\A3\d\d\z/;
    my $to = $res->{headers}{location} // '';
    return $to =~ m{/web/login(?:\?|\z)} ? 1 : 0;
}

# Odoo opened the session: read it back; the trusted-device cookie is
# handed to the caller and kept out of the jar
sub _totp_signed_in ($self, $res, $remember) {
    my $td = $self->{cookies}{ TRUSTED_DEVICE_COOKIE() };
    delete $self->{cookies}{ TRUSTED_DEVICE_COOKIE() };
    $self->{pending} = 0;
    my ($info) = $self->_rpc( '/web/session/get_session_info', {}, 'session.get_session_info' );
    Odoo::Error->throw( kind => 'fault', message => 'the code was accepted and Odoo opened no session', fault_class => 'oom.NoSession' )
        if !ref $info || !$info->{uid};
    $self->{identity} = _identity( $info, $self->{db} );
    my %id = %{ $self->{identity} };
    $id{trusted_device} = { name => TRUSTED_DEVICE_COOKIE, value => $td } if $remember && defined $td;
    return \%id;
}

# a trusted device: Odoo reads its cookie on the GET of the code form
sub _try_trusted_device ($self) {
    my $res  = $self->get('/web/login/totp');
    my $gone = $self->_totp_gone($res);
    return $self->_totp_signed_in( $res, 0 ) if defined $gone && !$gone;
    delete $self->{cookies}{ TRUSTED_DEVICE_COOKIE() };
    if ($gone) { $self->_forget_pending; Odoo::Error->throw( _pending_expired() ) }
    return { second_factor => 'totp', pending => 1 };
}

# the csrf token of Odoo's form
sub _csrf ($html) {
    for my $tag ( ( $html // '' ) =~ /<input\b[^>]*>/gi ) {
        next if $tag !~ /name=["']csrf_token["']/;
        return $1 if $tag =~ /value=["']([^"']*)["']/;
    }
    return undef;
}

# the words of the form's alert, as Odoo wrote them
sub _form_error ($html) {
    my ($t) = ( $html // '' ) =~ m{<p\b[^>]*alert-danger[^>]*>(.*?)</p>}is or return undef;
    $t =~ s/<[^>]*>//g;
    $t =~ s/&lt;/</g;
    $t =~ s/&gt;/>/g;
    $t =~ s/&quot;/"/g;
    $t =~ s/&#0*39;/'/g;
    $t =~ s/&amp;/&/g;
    $t =~ s/\s+/ /g;
    $t =~ s/\A | \z//g;
    return length $t ? $t : undef;
}

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
    Odoo::Error->throw( _second_factor_required() ) if $self->{pending};
    Odoo::Error->throw(
        kind        => 'fault',
        message     => "no session: authenticate first ($what)",
        fault_class => 'odoo.http.SessionExpiredException',
    ) if !defined $self->{session};
}

# one JSON-RPC post to a web route; returns (result, raw response)
sub _rpc ($self, $path, $params, $label, %opt) {
    my $body = $self->{json}->encode( { jsonrpc => '2.0', method => 'call', params => $params, id => ++$self->{id} } );
    my %headers = ( 'content-type' => 'application/json' );
    my $cookie = $self->_cookie_header;
    $headers{cookie} = $cookie if length $cookie;
    my $res = Odoo::Transport::post( $self->{http}, "$self->{url}$path", { content => $body, headers => \%headers }, idempotent => $opt{idempotent} );
    $self->_absorb_cookies($res);
    Odoo::Transport::refuse_by_policy( $res, $label );
    die Odoo::Transport::transport_error( $res, $label, idempotent => $opt{idempotent} ) if !$res->{success};
    my $data = eval { $self->{json}->decode( $res->{content} ) };
    if ( !$data || ref $data ne 'HASH' ) {
        my $peek = substr( $res->{content} // '', 0, 120 );
        Odoo::Error->throw( kind => 'transport', message => "$label: unparseable response: $peek", sent => 1, write => $opt{idempotent} ? 0 : 1 );
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
