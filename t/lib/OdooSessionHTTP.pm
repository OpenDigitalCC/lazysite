package OdooSessionHTTP;

# SM747 B: a stand-in for the HTTP client under OOM's session transport
# (Odoo::Transport::Session takes `http =>`), so the sign-in and the replay are
# tested through OOM's REAL transport with no network. It plays Odoo's web
# routes - authenticate, call_kw, get_session_info, destroy - for a table of
# people, and lets the test see everything that was posted: that the password
# travelled only to the authenticate route, and that every later call carried
# the session as a cookie and nothing in the URL.
#
# call_kw is served by OOM's own fake Odoo (Odoo::Test::FakeOdoo), so an
# operation runs end to end over the session transport.
use strict;
use warnings;
use JSON::PP ();

# people => { login => { password, uid, name, two_factor?, totp? } }, fake => FakeOdoo
#
# two_factor => 1 is the older shape: Odoo accepts the password and sets no session
# cookie at all. totp => CODE is Odoo's own authenticator step as OOM 0.27 reads it
# (SM1157): the password opens a HALF-OPEN session (a session_id cookie that the
# calls refuse), GET /web/login/totp serves the form with a csrf_token, and POST
# takes csrf_token, totp_token and remember. A right code opens the session; with
# remember it also sets Odoo's td_id cookie, and a later sign-in that carries that
# cookie is let straight in. Everything a request carried is kept for the test to
# search: posts (JSON routes), forms (the totp form posts).
sub new {
    my ( $class, %a ) = @_;
    return bless {
        people   => $a{people} // {},
        fake     => $a{fake},
        sessions => {},                    # sid => uid
        pending  => {},                    # sid => { login, csrf } - signed in as far as the password
        devices  => {},                    # td_id value => login
        forms    => [],
        gets     => [],
        posts    => [],
        n        => 0,
        json     => JSON::PP->new->utf8,
    }, $class;
}

sub posts    { return $_[0]{posts} }
sub forms    { return $_[0]{forms} }
sub gets     { return $_[0]{gets} }
sub pending  { return $_[0]{pending} }
sub devices  { return $_[0]{devices} }
sub sessions { return $_[0]{sessions} }

# Odoo forgets a session (it expired, or an administrator ended it).
sub expire     { my ( $s, $sid ) = @_; delete $s->{sessions}{$sid}; return }
sub down       { $_[0]{down}     = $_[1]; return }
sub expire_all { $_[0]{sessions} = {};    return }

sub post {
    my ( $s, $url, $opts ) = @_;
    my ($path) = $url =~ m{^https?://[^/]+(/.*)$};
    my $body   = $s->{json}->decode( $opts->{content} );
    my $cookie = $opts->{headers}{cookie} // '';
    push @{ $s->{posts} }, { url => $url, path => $path, cookie => $cookie, body => $body };
    return { success => 0, status => 599, reason => q{Internal Exception}, headers => {}, content => "could not connect: $opts->{content}" } if $s->{down};
    my $sid = _cookies($cookie)->{session_id};

    if ( $path eq '/web/session/authenticate' ) {
        my $p   = $body->{params};
        my $who = $s->{people}{ $p->{login} // '' };
        return $s->_fault( 'odoo.exceptions.AccessDenied', 'Access Denied' )
            unless $who && ( $who->{password} // '' ) eq ( $p->{password} // '' );

        if ( defined $who->{totp} ) {
            my $new = 'pend' . join '', map { sprintf '%02x', ( $s->{n}++ * 41 + $_ ) % 256 } 1 .. 20;
            $s->{pending}{$new} = { login => $p->{login} };
            $s->{td_seen} = _cookies($cookie)->{td_id};
            return $s->_ok( { uid => undef }, "session_id=$new; Path=/; HttpOnly" );
        }

        # A two-factor account: Odoo accepts the password and opens no session.
        return $s->_ok( { uid => undef } ) if $who->{two_factor};
        my $new = 'sid' . join '', map { sprintf '%02x', ( $s->{n}++ * 37 + $_ ) % 256 } 1 .. 20;
        $s->{sessions}{$new} = $who->{uid};
        return $s->_ok( $s->_info($who), "session_id=$new; Path=/; HttpOnly" );
    }
    return $s->_ok( $s->{fake}->call( 'common', 'version' ) ) if $path eq '/web/webclient/version_info';
    return $s->_ok(undef) if $path eq '/web/session/destroy' && defined $sid && delete $s->{pending}{$sid};
    my $uid = defined $sid ? $s->{sessions}{$sid} : undef;
    return $s->_fault( 'odoo.http.SessionExpiredException', 'Session expired' ) unless defined $uid;
    return $s->_ok(undef) if $path eq '/web/session/destroy' && delete $s->{sessions}{$sid};
    if ( $path eq '/web/session/get_session_info' ) {
        my ($who) = grep { $_->{uid} == $uid } values %{ $s->{people} };
        return $s->_ok( $s->_info($who) );
    }
    if ( $path =~ m{\A/web/dataset/call_kw/([^/]+)/([^/]+)\z} ) {
        my ( $model, $method ) = ( $1, $2 );
        my $r = eval {
            $s->{fake}->call( 'object', 'execute_kw', 'db', $uid, 'session', $model, $method,
                $body->{params}{args}, $body->{params}{kwargs} );
        };
        if ( my $e = $@ ) {
            return $s->_fault( ( ref $e ? $e->{fault_class} : undef ) // 'odoo.exceptions.UserError',
                ( ref $e ? $e->message : 'error' ) );
        }
        return $s->_ok($r);
    }
    return { success => 0, status => 404, reason => 'Not Found', headers => {}, content => '' };
}

sub _info {
    my ( $s, $who ) = @_;
    return {
        uid => $who->{uid}, username => $who->{login} // $who->{name}, name => $who->{name},
        partner_id   => 10 + $who->{uid},
        user_context => { lang => 'en_GB', tz => 'Europe/London', uid => $who->{uid} },
        user_companies => { current_company => 1, allowed_companies => { 1 => { id => 1, name => 'Demo' } } },
        is_admin => JSON::PP::false, is_system => JSON::PP::false, db => 'shopdb',
    };
}

sub _ok {
    my ( $s, $result, $set_cookie ) = @_;
    return {
        success => 1, status => 200, reason => 'OK',
        headers => { ( $set_cookie ? ( 'set-cookie' => $set_cookie ) : () ) },
        content => $s->{json}->encode( { jsonrpc => '2.0', id => 1, result => $result } ),
    };
}

sub _fault {
    my ( $s, $class, $msg ) = @_;
    return {
        success => 1, status => 200, reason => 'OK', headers => {},
        content => $s->{json}->encode( { jsonrpc => '2.0', id => 1,
                error => { code => 200, message => 'Odoo Server Error', data => { name => $class, message => $msg } } } ),
    };
}

# --- Odoo's own authenticator step (auth_totp), as OOM 0.27 reads it ------------

sub _cookies {
    my ($h) = @_;
    return { map { /^\s*([^=]+)=(.*)$/ ? ( $1 => $2 ) : () } split /;\s*/, $h // '' };
}

# Odoo forgets a half-open sign-in (it lapsed).
sub expire_pending { $_[0]{pending} = {}; return }

sub _redirect {
    my ( $s, $to, $set ) = @_;
    return { success => 1, status => 303, reason => 'See Other',
        headers => { location => "https://odoo.example$to", ( $set ? ( 'set-cookie' => $set ) : () ) }, content => '' };
}

sub _form {
    my ( $s, $csrf, $error ) = @_;
    return qq{<form method="POST" action=""><input type="hidden" name="csrf_token" value="$csrf"/>}
        . qq{<input id="totp_token" name="totp_token"/>}
        . ( defined $error ? qq{<p class="alert alert-danger" role="alert">$error</p>} : '' )
        . qq{<input type="checkbox" name="remember" value="1"/></form>};
}

# Opening the session for a person who is pending, and the trusted-device cookie
# when the form asked to remember.
sub _open {
    my ( $s, $psid, $remember ) = @_;
    my $login = delete( $s->{pending}{$psid} )->{login};
    my $who   = $s->{people}{$login};
    my $new   = 'sid' . join '', map { sprintf '%02x', ( $s->{n}++ * 37 + $_ ) % 256 } 1 .. 20;
    $s->{sessions}{$new} = $who->{uid};
    my @set = ("session_id=$new; Path=/; HttpOnly");
    if ($remember) {
        my $td = 'TD' . join '', map { sprintf '%02x', ( $s->{n}++ * 29 + $_ ) % 256 } 1 .. 18;
        $s->{devices}{$td} = $login;
        push @set, "td_id=$td; Max-Age=7776000; Path=/; HttpOnly";
    }
    return $s->_redirect( '/odoo', \@set );
}

sub get {
    my ( $s, $url, $opts ) = @_;
    my ($path) = $url =~ m{^https?://[^/]+(/.*)$};
    my $c = _cookies( $opts->{headers}{cookie} );
    push @{ $s->{gets} }, { path => $path, cookie => $opts->{headers}{cookie} // '' };
    return { success => 0, status => 404, reason => 'Not Found', headers => {}, content => '' } if $path ne '/web/login/totp';
    my $psid = $c->{session_id} // '';
    return $s->_redirect('/odoo') if defined $s->{sessions}{$psid};
    my $p = $s->{pending}{$psid} or return $s->_redirect('/web/login');

    # a trusted device: Odoo reads its cookie at the form and opens the session
    if ( defined $c->{td_id} && ( $s->{devices}{ $c->{td_id} } // '' ) eq $p->{login} ) {
        return $s->_open( $psid, 0 );
    }
    $p->{csrf} = 'csrf-' . ++$s->{n};
    return { success => 1, status => 200, reason => 'OK', headers => {}, content => $s->_form( $p->{csrf}, undef ) };
}

sub post_form {
    my ( $s, $url, $f, $opts ) = @_;
    my ($path) = $url =~ m{^https?://[^/]+(/.*)$};
    my $c    = _cookies( $opts->{headers}{cookie} );
    my $psid = $c->{session_id} // '';
    push @{ $s->{forms} }, { path => $path, fields => { %$f }, cookie => $opts->{headers}{cookie} // '',
        agent => $opts->{headers}{'user-agent'} };
    my $p = $s->{pending}{$psid} or return $s->_redirect('/web/login');
    return { success => 0, status => 400, reason => 'Bad Request', headers => {}, content => 'csrf' }
        if ( $f->{csrf_token} // '' ) ne ( $p->{csrf} // 'none' );
    my $who = $s->{people}{ $p->{login} };

    # Odoo names a trusted device after the browser it reads; without one it fails
    return { success => 0, status => 500, reason => 'Internal Server Error', headers => {}, content => '' }
        if $f->{remember} && !length( $opts->{headers}{'user-agent'} // '' );
    if ( ( $f->{totp_token} // '' ) ne $who->{totp} ) {
        $s->{tries}{ $p->{login} }++;
        my $e = $s->{tries}{ $p->{login} } > ( $s->{limit} // 3 )
            ? 'Too many login failures, please wait a bit before trying again.'
            : 'Verification failed, please double-check the 6-digit code';
        return { success => 1, status => 200, reason => 'OK', headers => {}, content => $s->_form( $p->{csrf}, $e ) };
    }
    return $s->_open( $psid, $f->{remember} );
}

1;
