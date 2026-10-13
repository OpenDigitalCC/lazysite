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

# people => { login => { password, uid, name, two_factor? } }, fake => FakeOdoo
sub new {
    my ( $class, %a ) = @_;
    return bless {
        people   => $a{people} // {},
        fake     => $a{fake},
        sessions => {},                    # sid => uid
        posts    => [],
        n        => 0,
        json     => JSON::PP->new->utf8,
    }, $class;
}

sub posts    { return $_[0]{posts} }
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
    my ($sid) = $cookie =~ /\Asession_id=(.+)\z/;

    if ( $path eq '/web/session/authenticate' ) {
        my $p   = $body->{params};
        my $who = $s->{people}{ $p->{login} // '' };
        return $s->_fault( 'odoo.exceptions.AccessDenied', 'Access Denied' )
            unless $who && ( $who->{password} // '' ) eq ( $p->{password} // '' );

        # A two-factor account: Odoo accepts the password and opens no session.
        return $s->_ok( { uid => undef } ) if $who->{two_factor};
        my $new = 'sid' . join '', map { sprintf '%02x', ( $s->{n}++ * 37 + $_ ) % 256 } 1 .. 20;
        $s->{sessions}{$new} = $who->{uid};
        return $s->_ok( $s->_info($who), "session_id=$new; Path=/; HttpOnly" );
    }
    return $s->_ok( $s->{fake}->call( 'common', 'version' ) ) if $path eq '/web/webclient/version_info';
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

1;
