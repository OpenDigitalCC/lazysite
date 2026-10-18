#!/usr/bin/perl

# SM747 CU: THE ODOO ENDPOINT - a page's own JavaScript runs an Odoo binding.
#
# WHY A DIRECT-CGI ENDPOINT, as the data extension has one. A page asking Odoo
# for something is a visitor, usually anonymous, and the control API is the
# sysop's and the agent's door. This endpoint answers for BINDINGS - handlers of
# type odoo that an operator made under manage_connectors - and for nothing
# else: no model, no method, no domain is ever named in a request here.
#
#   GET  ?csrf=1                 tokens for this browser: the visitor token
#                                (minting the visitor cookie if there is none)
#                                and, for a signed-in account, the session one;
#                                for a person signed in to Odoo, who they are
#                                (the display name - SM1145)
#   GET  ?binding=ID&field=v...  run a READ binding
#   POST {binding, params}       run a binding (a write plans, or applies when
#                                the binding says immediate)
#   POST {plan, confirm: true}   apply a plan this caller made
#   POST {calls: [{binding, params}, ...]}
#                                up to 10 of the above in one request, answered
#                                in order, each its own status (SM1146)
#   POST {signin: true, login, password, visitor_token}
#                                sign a person in to Odoo (SM747 B): the password goes
#                                to Odoo through OOM and nowhere else; the answer sets
#                                the Odoo session cookie
#   POST {signin_code: true, code, remember, visitor_token}
#                                the second request of a two-factor sign-in (SM1157): the
#                                authenticator code, for the half-open session the password
#                                request left in its own signed cookie; a wrong code leaves
#                                that session open for another try
#   POST {signout: true, visitor_token}
#                                end that session at Odoo and clear the cookie (and a
#                                half-open sign-in, if one is waiting)
#
# IT VERIFIES ITS OWN CALLER (SM411), as the data endpoint does: only the
# processor and the manager API are wrapped, so X-Remote-User arrives here
# exactly as a client sent it. The session cookie is verified; anything else is
# a visitor.
#
# THE MODE IS WHAT THE CALLER IS. A verified session is `authenticated` where
# the binding admits that mode; everywhere else the caller is a member of the
# public, as the form handler treats every poster (SM579: "the form handler
# says public because anyone could have posted"). A signed-in account reaching
# a public binding as public gains nothing an anonymous visitor lacks.
#
# THE COLD PATH IS LIGHT (SM1147). Lazysite::Odoo and the modules under it are
# loaded by the branches that reach Odoo, and by no other: `?csrf=1` - the call
# every page makes first - and a request refused before anything is run (the
# wrong method, a body that is not JSON, a missing token on a sign-in) answer
# from the visitor and session cookies alone.
#
# A STATE-CHANGING POST NEEDS ITS TOKEN (OA5, outcome 9, Q1): the session's
# CSRF token for an authenticated call, the visitor-bound token for a public
# one - and the visitor cookie is SameSite=Strict, so a cross-site POST arrives
# without it.

use strict;
use warnings;
use JSON::PP ();

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
}

use Lazysite::Timing (); # SM1144: after the lib search, so its load phase covers what is loaded below

exit main() if !caller;

# Headers set for this response before the body - the visitor cookie, when one
# is minted. Reset at the top of every request.
our @EXTRA;

# SM1160: the Odoo-minted site session the request carries, if any (see main).
our $SITE_SESSION;

sub reply {
    my ( $status, $data ) = @_;
    my $body = JSON::PP->new->utf8->canonical->encode($data);
    binmode STDOUT;
    print "Status: $status\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n";
    # What a visitor sees depends on who they are: never cached by anything.
    print "Cache-Control: no-store\r\n";
    my $tm = Lazysite::Timing::header_line();    # SM1144
    print "$tm\r\n" if length $tm;
    print "$_\r\n" for @EXTRA;
    print 'Content-Length: ' . length($body) . "\r\n\r\n";
    print $body;
    return 0;
}

# A refusal's status comes from its kind, by the one map every surface uses.
sub refuse {
    my ($r) = @_;
    return reply( _refusal_pair($r) );
}

# ( status, data ): a refusal and the status its kind maps to.
sub _refusal_pair {
    my ($r) = @_;
    require Lazysite::Manager::Common;
    return ( Lazysite::Manager::Common::refusal_status( $r->{kind} ), $r );
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

# SM1144: an Odoo call, timed as the `call` phase. The sites agent measured an Odoo
# read at about 550 ms of which Odoo's own answer is 50-90; this is what lets the
# rest be read off the response rather than inferred.
sub _timed {
    my ($code) = @_;
    Lazysite::Timing::to('call');
    Lazysite::Odoo::reset_via();    # SM1164: the phase says which path answered
    my @r   = $code->();
    my $via = Lazysite::Odoo::last_via();
    Lazysite::Timing::desc( 'call', $via eq 'daemon' ? 'oomd' : 'in-process' ) if defined $via;
    Lazysite::Timing::to('render');
    return wantarray ? @r : $r[0];
}

sub main {
    local @EXTRA = ();
    my $docroot = $ENV{DOCUMENT_ROOT} // '';
    Lazysite::Timing::begin();      # SM1144: where this request's time goes
    return reply( '500 Internal Server Error', { ok => 0, error => 'no document root' } )
        unless length $docroot && -d $docroot;
    my $method = $ENV{REQUEST_METHOD} // 'GET';
    return reply( '405 Method Not Allowed',
        { ok => 0, error => 'this endpoint takes GET to read and POST to change' } )
        unless $method eq 'GET' || $method eq 'POST';

    no warnings 'once';
    Lazysite::Timing::to('load'); # SM1144: the modules this request needs, up to the identity
    require Lazysite::Manager::Plugins;
    require Lazysite::Paths;
    Lazysite::Timing::configure( Lazysite::Paths::lazysite_dir($docroot) );
    local $Lazysite::Manager::Plugins::DOCROOT = $docroot;
    return reply( '403 Forbidden',
        { ok => 0, kind => 'disabled',
            error => 'The Odoo extension is disabled. A sysop can enable it on the Extensions page.' } )
        unless Lazysite::Manager::Plugins::plugin_enabled('plugins/odoo.pl');

    # SM1147: the visitor cookie, the session cookie and the identity cookie are
    # read by these small modules; Lazysite::Odoo (the engine, with Egress under
    # it) is _engine()'s, called by the branches that reach Odoo.
    require Lazysite::Odoo::Visitor;
    require Lazysite::Odoo::SiteSignin;    # SM1160: configuration only, loads no engine
    local $Lazysite::Odoo::DOCROOT          = $docroot;
    local $Lazysite::Odoo::Visitor::DOCROOT = $docroot;

    # THE IDENTITY, verified here.
    Lazysite::Timing::to('identity');      # SM1144
    require Lazysite::Auth::Session;
    local $Lazysite::Auth::Session::LAZYSITE_DIR = Lazysite::Paths::lazysite_dir($docroot);
    my ($session) = Lazysite::Auth::Session::verify_session_cookie( odoo_stale_ok => 1 );
    my $user = ( ref $session eq 'HASH' ) ? ( $session->{user} // '' ) : '';

   # SM1160: a session the Odoo sign-in minted (identity `odoo:<login>`). One that is past
   # its time without Odoo being asked is no identity here either - it holds nothing until
   # the ?csrf=1 refresh below asks Odoo - but it is remembered, to be renewed or ended.
    local $SITE_SESSION = ( ref $session eq 'HASH' && $session->{odoo} ) ? $session : undef;
    $user = '' if $SITE_SESSION && $SITE_SESSION->{stale};
    my @groups;
    my $caps = {};
    if ( length $user ) {
        my $g = $session->{groups};
        @groups = grep { length } ( ref $g eq 'ARRAY' ? @$g : split /\s*,\s*/, ( $g // '' ) );
        require Lazysite::Auth::Settings;
        local $Lazysite::Auth::Settings::AUTH_DIR = Lazysite::Paths::lazysite_dir($docroot) . '/auth';

      # SM1160: an Odoo-minted identity holds no capability, whatever group a record names
        $caps = $SITE_SESSION ? {} : ( Lazysite::Auth::Settings::caps_for($user) || {} );
        Lazysite::Timing::operator(1) if $caps->{ui}; # SM1144: an operator is shown the phases
    }
    Lazysite::Timing::to('render');
    my $visitor = Lazysite::Odoo::Visitor::key_from_cookie( $ENV{HTTP_COOKIE} // '' );

    # B: the person's Odoo session, if the cookie is one this server minted and it
    # is inside its twelve hours. A credential: it goes to Odoo and nowhere else.
    require Lazysite::Odoo::Session;
    my $odoo_session = Lazysite::Odoo::Session::sid_from_cookie( $ENV{HTTP_COOKIE} // '' );
    my $ip           = _ip($docroot);

    # SM1157: a half-open two-factor sign-in, and the trusted-device cookie. Neither is a
    # session: sid_from_cookie does not read the first, and the second is only ever
    # handed back to Odoo.
    my $pending = Lazysite::Odoo::Session::pending_from_cookie( $ENV{HTTP_COOKIE} // '' );
    my $device  = Lazysite::Odoo::Session::device_from_cookie( $ENV{HTTP_COOKIE}  // '' );

    my $q = _query();
    if ( ( $q->{csrf} // '' ) eq '1' ) {
        unless ($visitor) {
            my ( $key, $cookie ) = Lazysite::Odoo::Visitor::mint();
            return reply( '503 Service Unavailable',
                { ok => 0, kind => 'unavailable', error => 'a visitor key cannot be made on this host' } )
                unless $key;
            $visitor = $key;
            push @EXTRA, Lazysite::Odoo::Visitor::set_cookie_header( $cookie, secure => $ENV{HTTPS} ? 1 : 0 );
        }
        my $who = $odoo_session ? _who_is_signed_in() : undef;
        if ( Lazysite::Odoo::SiteSignin::enabled( Lazysite::Paths::lazysite_dir($docroot) ) ) {
            ( $user, $who, $odoo_session ) = _site_state( $docroot, $user, $who, $odoo_session );
        }
        return reply( '200 OK',
            { ok => 1, visitor_token => Lazysite::Odoo::Visitor::csrf_token($visitor),
                odoo_signed_in => ( $odoo_session ? 1 : 0 ),
                ( $who ? ( identity => $who ) : () ),
                ( length $user ? ( token => Lazysite::Auth::Session::generate_csrf_token($user) ) : () ) } );
    }

    my $len = $ENV{CONTENT_LENGTH} || 0;
    my ( $req, $raw ) = ( undef, '' );
    if ( $method eq 'POST' ) {
        return reply( '413 Payload Too Large', { ok => 0, kind => 'too-large', error => 'body too large' } )
            if $len > 64 * 1024;
        read( STDIN, $raw, $len ) if $len;
        $req = eval { JSON::PP->new->utf8->decode($raw) };
        return reply( '400 Bad Request', { ok => 0, kind => 'invalid', error => 'the body must be a JSON object' } )
            unless ref $req eq 'HASH';

        # B: signing in and out. Neither names a binding, and both are a POST that
        # needs the visitor token (bound to the visitor cookie, which SameSite=Strict
        # keeps from a cross-site request): a forged form must not sign a victim in
        # as somebody else.
        # SM1159 (L2): conf `signin_addresses` / `signin_addresses_deny` limit where a
        # sign-in may come from - the password step and the code step alike. The refusal
        # comes first: before the token is looked at, before the password reaches the
        # engine, before the rate limiter counts it (a refused address is not a rate).
        # Signing out is never refused. These two requests name no binding, so a
        # binding's own narrowing is applied to the calls of a session binding instead
        # (_address_refusal).
        if ( $req->{signin} || $req->{signin_code} ) {
            require Lazysite::Auth::AddressScope;
            return reply( '403 Forbidden',
                { ok => 0, kind => 'address', error => 'Sign-in is not available from your address.' } )
                if Lazysite::Auth::AddressScope::refuse_signin( Lazysite::Paths::lazysite_dir($docroot), 'api' );
        }
        if ( $req->{signin} || $req->{signout} ) {
            my %ctx = ( mode => 'public', visitor_key => $visitor );
            return _csrf_refusal( \%ctx ) unless _csrf_ok( \%ctx, $req );
        }
    }

    # From here a request reaches the engine, and so Odoo.
    _engine($docroot);
    require Lazysite::Util;
    my %who = ( user => $user, groups => \@groups, caps => $caps, visitor => $visitor, ip => $ip,
        host    => Lazysite::Util::request_host(), odoo_session => $odoo_session,
        pending => $pending,                       device       => $device );

    if ( $method eq 'GET' ) {
        $who{odoo_session} = _refresh_identity(%who);
        my $id = delete $q->{binding};
        my ( $b, $why ) = Lazysite::Odoo::find_binding($id);
        return refuse( { ok => 0, kind => 'not-found', error => $why } ) unless $b;
        if ( my $r = _address_refusal($b) ) { return refuse($r) }
        return reply( '405 Method Not Allowed',
            { ok => 0, kind => 'method', error => 'this binding changes data - send it as a POST with its token' } )
            if _writes($b);
        return _answer( _timed( sub { Lazysite::Odoo::call( $b, $q, _ctx( $b, %who ), strict => 1 ) } ), \%who );
    }

    return _signin( $req, %who )  if $req->{signin};
    return _signin_code( $req, %who ) if $req->{signin_code};
    return _signout( $req, %who ) if $req->{signout};
    $who{odoo_session} = _refresh_identity(%who);
    return _batch( $req, \%who ) if exists $req->{calls};
    return reply( _post_one( $req, \%who ) );
}

# SM1147: the engine, loaded by the branches that need it. DOCROOT is set after
# the require because the module's own `our $DOCROOT = ''` runs at load.
sub _engine {
    my ($docroot) = @_;
    require Lazysite::Odoo;
    $Lazysite::Odoo::DOCROOT = $docroot;
    return;
}

# SM1159: a session binding may carry its own `signin_addresses` /
# `signin_addresses_deny`, which can only narrow the site's. The sign-in requests
# name no binding, so the endpoint cannot know at sign-in which binding's page the
# person is on; the binding's rule is therefore held where the binding IS named, on
# its calls: a call from an address the binding refuses is not run, session or no
# session. undef when the call may go on, else the refusal.
sub _address_refusal {
    my ($b) = @_;
    return undef unless $b && ( $b->{credential} // '' ) eq 'session';
    my @allow = @{ $b->{signin_addresses}      || [] };
    my @deny  = @{ $b->{signin_addresses_deny} || [] };
    return undef unless @allow || @deny;
    require Lazysite::Auth::AddressScope;
    return undef unless Lazysite::Auth::AddressScope::refuse_signin(
        Lazysite::Paths::lazysite_dir( $ENV{DOCUMENT_ROOT} // '' ), 'api', \@allow, \@deny, $b->{id} );
    return { ok => 0, kind => 'address', error => 'This page is not available from your address.' };
}

# SM1145: who is signed in, for a page to show - the display name
# from the identity cookie this server signed, while it is inside its time, and
# nothing else of the person. undef when there is nothing to trust: the cookie is
# absent, ended or altered. Nothing is asked of Odoo here (the next call that
# reaches Odoo freshens an ended cookie, OI3), so a page that only wants a name
# costs no Odoo call. Presentation only (OI4): nothing is permitted by it.
sub _who_is_signed_in {
    require Lazysite::Odoo::Identity;
    my $id = Lazysite::Odoo::Identity::identity_from_cookie( $ENV{HTTP_COOKIE} // '',
        ttl => Lazysite::Odoo::Identity::configured_ttl() );
    return Lazysite::Odoo::Identity::shown($id);
}

# One POST that names a binding, or confirms a plan: ( status, data ) for reply.
# A single request and each call of a batch (SM1146) go through THIS function, so
# a call in a batch is checked, authorised, rate-capped, recorded and audited
# exactly as the same call sent alone: the same token check, the same engine
# call. $who is mutated when Odoo ends the person's session, so a later call in
# the same batch does not run on a session that has gone.
sub _post_one {
    my ( $req, $who ) = @_;
    if ( $req->{confirm} ) {
        # A confirm names no binding: which binding, and so which mode, is the
        # plan's. The caller's token must fit what the caller is.
        my %ctx = _ctx( undef, %$who );
        return _csrf_pair( \%ctx ) unless _csrf_ok( \%ctx, $req );
        return _settle( _timed( sub { Lazysite::Odoo::confirm( $req->{plan}, %ctx ) } ), $who );
    }

    my ( $b, $why ) = Lazysite::Odoo::find_binding( $req->{binding} );
    return _refusal_pair( { ok => 0, kind => 'not-found', error => $why } ) unless $b;
    if ( my $r = _address_refusal($b) ) { return _refusal_pair($r) }
    my %ctx = _ctx( $b, %$who );

    # SM1168 (OOM Lab, session mode): a binding that runs as the person signed in
    # to Odoo, from a request with NO Odoo session, is answered "sign in" BEFORE
    # the token check. The check ran first and, with no session to hold a token,
    # failed as 403 csrf - and the browser helper opens its sign-in prompt only on
    # 401 signin-required, so the person was never asked. The engine's gate is the
    # one that refuses it (and records the refusal, SM771). This weakens no check:
    # nothing runs and nothing of the binding is told, only "you are not signed
    # in", which the caller already knows. A request WITH a session goes on to the
    # token check below, unchanged. The binding's address rule (SM1159) is held
    # first, above: from an address it refuses, the call is refused, not asked to
    # sign in, since a sign-in from there would be refused too.
    if ( ( $b->{credential} // '' ) eq 'session' && !length( $ctx{odoo_session} // '' ) ) {
        my ( undef, $refusal ) = Lazysite::Odoo::gate( $b, %ctx );
        return _refusal_pair($refusal);
    }
    return _csrf_pair( \%ctx ) unless _csrf_ok( \%ctx, $req, $b );
    return ( '400 Bad Request', { ok => 0, kind => 'invalid', error => 'params must be an object' } )
        if defined $req->{params} && ref $req->{params} ne 'HASH';
    return _settle( _timed( sub { Lazysite::Odoo::call( $b, $req->{params} // {}, %ctx, strict => 1 ) } ), $who );
}

# SM1146 (the OOM Lab's P2): SEVERAL CALLS IN ONE REQUEST. A page with N reads
# paid this endpoint's start-up N times; a batch pays it once. The cap is
# $MAX_BATCH calls, said in the refusal. The tokens are the request's - one visitor
# token or one session token, sent once - and each call is checked against them
# for what that call's binding needs. A call that fails does not stop the others:
# each answer is the one the call alone would have had, with its own `status`.
# Writes follow the same plan/apply rules as singly (a binding that plans returns
# a plan to confirm; `apply: immediate` applies), because it is the same function.
# A batch carries calls and confirms, never a sign-in or sign-out.
our $MAX_BATCH = 10;

sub _batch {
    my ( $req, $who ) = @_;
    my $calls = $req->{calls};
    return reply( '400 Bad Request',
        { ok => 0, kind => 'invalid', error => 'calls must be a list of {binding, params}' } )
        unless ref $calls eq 'ARRAY';
    return reply( '400 Bad Request',
        { ok => 0, kind => 'invalid', error => "a batch holds 1 to $MAX_BATCH calls" } )
        unless @$calls >= 1 && @$calls <= $MAX_BATCH;
    my @results;
    for my $item (@$calls) {
        my ( $status, $data );
        if ( ref $item ne 'HASH' || grep { exists $item->{$_} } qw(signin signout calls) ) {
            ( $status, $data ) = ( '400 Bad Request',
                { ok => 0, kind => 'invalid', error => 'a batch call is a {binding, params} or a {plan, confirm}' } );
        }
        else {
            # the request's tokens, never one the call carries for itself
            my %one = %$item;
            delete @one{qw(visitor_token token)};
            exists $req->{$_} and $one{$_} = $req->{$_} for qw(visitor_token token);
            ( $status, $data ) = _post_one( \%one, $who );
        }
        my ($code) = $status =~ /\A(\d+)/;
        push @results, { %$data, status => 0 + $code };
    }
    return reply( '200 OK', { ok => 1, results => \@results } );
}

# The call's context: authenticated where the account is verified and the
# binding admits that mode (or, for a confirm, always - the plan's owner check
# is what decides); public otherwise. The visitor key travels as the key, and
# the engine turns it into a hash before anything is recorded.
sub _ctx {
    my ( $b, %w ) = @_;

    # B: a session binding runs as the person signed in to Odoo: authenticated mode,
    # their session, and no visitor key in the engine (a record names the session).
    # The visitor key stays here only to check the token.
    return (
        mode         => 'authenticated',  ip               => $w{ip}, host => $w{host},
        odoo_session => $w{odoo_session}, csrf_visitor_key => $w{visitor},
    ) if $b && ( $b->{credential} // '' ) eq 'session';
    my $authn = length $w{user} && ( !$b || $b->{modes}{authenticated} );
    return (
        mode   => ( $authn ? 'authenticated' : 'public' ),
        actor  => ( $authn ? $w{user}        : '' ),
        groups => $w{groups},
        caps   => $w{caps},
        ip     => $w{ip},
        ( $w{visitor} ? ( visitor_key => $w{visitor} ) : () ),
        ( $w{odoo_session} && !$b ? ( odoo_session => $w{odoo_session}, csrf_visitor_key => $w{visitor} ) : () ),
        host => $w{host},    # E-Q1: a domain's binding runs only for its own host
    );
}

sub _csrf_ok {
    my ( $ctx, $req, $b ) = @_;

    # B: a person signed in to Odoo may have no account on this site, so what a
    # session binding (or a confirm of its plan) carries is the visitor token -
    # bound to the visitor cookie, which a cross-site request does not send.
    if ( length( $ctx->{odoo_session} // '' ) && ( !$b || ( $b->{credential} // '' ) eq 'session' ) ) {
        return 1 if Lazysite::Odoo::Visitor::verify_csrf( $req->{visitor_token} // '', $ctx->{csrf_visitor_key} );
        return 0 if $b;
    }
    if ( $ctx->{mode} eq 'authenticated' ) {
        my $t = $ENV{HTTP_X_CSRF_TOKEN} // $req->{token} // '';
        return Lazysite::Auth::Session::verify_csrf_token( $t, $ctx->{actor} );
    }
    return Lazysite::Odoo::Visitor::verify_csrf( $req->{visitor_token} // '', $ctx->{visitor_key} );
}

sub _csrf_refusal {
    my ($ctx) = @_;
    return reply( _csrf_pair($ctx) );
}

sub _csrf_pair {
    my ($ctx) = @_;
    return ( '403 Forbidden',
        { ok => 0, kind => 'csrf',
            error => ( $ctx->{mode} eq 'public' && !$ctx->{visitor_key} )
            ? 'no visitor key on this request - fetch tokens from ?csrf=1 first'
            : 'missing or stale token - fetch fresh ones from ?csrf=1 and retry' } );
}

sub _answer {
    my ( $r, $who ) = @_;
    return reply( _settle( $r, $who ) );
}

# ( status, data ) for an engine answer.
sub _settle {
    my ( $r, $who ) = @_;

    # B: Odoo ended the person's session (or no longer accepts it). The cookie goes,
    # and the body says to sign in - nothing else was run in its place. SM1146: and
    # a later call of the same batch has no session to run on.
    if ( delete $r->{clear_session} ) {
        _clear_cookies();
        $who->{odoo_session} = undef if $who;
    }
    return _refusal_pair($r) unless $r->{ok};
    return ( '200 OK', $r );
}

# The credential cookie and the identity cookie go together: a person whose
# session has ended is shown no identity either.
sub _clear_cookies {
    push @EXTRA, Lazysite::Odoo::Session::clear_cookie_header( _cookie_scope() );
    require Lazysite::Odoo::Identity;
    push @EXTRA, Lazysite::Odoo::Identity::clear_cookie_header( secure => ( $ENV{HTTPS} ? 1 : 0 ) );
    _end_site_session();
    return;
}

# SM1160 (ruling 3): the Odoo session ends and the site session goes with it - its sid is
# revoked (so a copy of the cookie is dead too) and both site cookies are cleared. Every way
# the Odoo session ends comes through _clear_cookies: signing out, Odoo answering
# session-ended to a call, the identity refresh finding it gone.
sub _end_site_session {
    my ($why) = @_;
    return unless $SITE_SESSION;
    _engine( $ENV{DOCUMENT_ROOT} );
    Lazysite::Odoo::site_session_end( sid => $SITE_SESSION->{sid}, user => $SITE_SESSION->{user},
        ip => _ip( $ENV{DOCUMENT_ROOT} ), why => $why // 'odoo session ended' );
    require Lazysite::Auth::Session;
    push @EXTRA, Lazysite::Auth::Session::odoo_clear_headers( secure => ( $ENV{HTTPS} ? 1 : 0 ) );
    $SITE_SESSION = undef;
    return;
}

# SM1160 (ruling 3): what ?csrf=1 says about the site session on a site that opted in.
# Free of Odoo calls (SM1145/SM1147) except the one the ruling allows: when the record
# was last checked more than odoo_identity_ttl ago, Odoo is asked ONCE (is the session
# still the person's, which mapped groups do they hold) and the record renewed - or, if
# Odoo has ended the session, the site session ends with it. An Odoo session with NO site
# session behind it is a site session that ended (signed out at the wrapper, revoked,
# lapsed): the Odoo session is ended too, so one never outlives the other.
# Returns ( $user, $who, $odoo_session ) as they now stand.
sub _site_state {
    my ( $docroot, $user, $who, $odoo_session ) = @_;
    require Lazysite::Odoo::Identity;
    if ($SITE_SESSION) {
        if ( $SITE_SESSION->{stale} ) {
            unless ($odoo_session) { _end_site_session('odoo session is gone'); return ( '', undef, undef ) }
            _engine($docroot);
            my $f = _timed( sub {
                    Lazysite::Odoo::site_session_renew( session_id => $odoo_session, site_sid => $SITE_SESSION->{sid} );
            } );
            if ( $f->{ok} ) {
                _identity_cookie_out( $f->{identity_cookie} );
                $user = $SITE_SESSION->{user};
                $who  = { name => $f->{name} } if defined $f->{name} && length $f->{name};
            }
            elsif ( $f->{clear_session} ) { _clear_cookies(); return ( '', undef, undef ) }
            else { return ( '', undef, $odoo_session ) } # could not ask: holds nothing yet
        }
        $who //= Lazysite::Odoo::Identity::shown( { name => $SITE_SESSION->{name} } ) if length( $SITE_SESSION->{name} // '' );
        return ( $user, $who, $odoo_session );
    }
    if ($odoo_session) {
        _engine($docroot);
        Lazysite::Odoo::sign_out( session_id => $odoo_session, ip => _ip($docroot) );
        _clear_cookies();
        return ( '', undef, undef );
    }
    return ( '', undef, undef );
}

sub _identity_cookie_out {
    my ($value) = @_;
    return unless defined $value;
    require Lazysite::Odoo::Identity;
    push @EXTRA, Lazysite::Odoo::Identity::set_cookie_header( $value,
        secure => ( $ENV{HTTPS} ? 1 : 0 ), ttl => Lazysite::Odoo::identity_ttl() );
    return;
}

# OI3: the identity cookie is short, and refreshed on the next call after it has
# ended. A person with a session and no (or an ended) identity cookie is asked of
# Odoo, once, through their own session. If Odoo has ended the session both
# cookies are cleared and the call that follows is told to sign in. A failure to
# ask leaves the person as they were, with nothing to show.
sub _refresh_identity {
    my (%who) = @_;
    return $who{odoo_session} unless length( $who{odoo_session} // '' );
    require Lazysite::Odoo::Identity;
    return $who{odoo_session}
        if Lazysite::Odoo::Identity::identity_from_cookie( $ENV{HTTP_COOKIE} // '', ttl => Lazysite::Odoo::identity_ttl() );
    my $f = _timed( sub { Lazysite::Odoo::refresh_identity( session_id => $who{odoo_session} ) } );
    if ( $f->{ok} ) { _identity_cookie_out( $f->{identity_cookie} ); return $who{odoo_session} }
    if ( $f->{clear_session} ) { _clear_cookies(); return undef }
    return $who{odoo_session};
}

sub _cookie_scope {
    return ( path => ( $ENV{SCRIPT_NAME} // '' ), secure => ( $ENV{HTTPS} ? 1 : 0 ) );
}

# B: sign a person in to Odoo. The login and the password are the two things in
# the body that are never logged, never echoed and never stored: they go to the
# engine, which hands the password to OOM and keeps nothing. The answer carries
# the signed session cookie (HttpOnly, SameSite=Strict, Secure over HTTPS, scoped
# to this endpoint) and a name for a greeting; the session id is in no body.
sub _signin {
    my ( $req, %who ) = @_;
    my %ctx = ( mode => 'public', visitor_key => $who{visitor} );
    return _csrf_refusal( \%ctx ) unless _csrf_ok( \%ctx, $req );
    return reply( '400 Bad Request', { ok => 0, kind => 'invalid', error => 'a login and a password are both required' } )
        if ref $req->{login} || ref $req->{password};
    my $r = _timed( sub {
            Lazysite::Odoo::sign_in( login => $req->{login}, password => $req->{password}, ip => $who{ip},
                secure     => ( $ENV{HTTPS} ? 1 : 0 ), trusted_device => $who{device},
                user_agent => $ENV{HTTP_USER_AGENT} );
    } );
    return refuse($r) unless $r->{ok};
    push @EXTRA, Lazysite::Odoo::Session::clear_device_header( _cookie_scope() ) if $r->{clear_device};

    # SM1157: Odoo wants the authenticator code. The half-open session is carried to
    # the next request in its own signed cookie; nothing here is a sign-in yet.
    if ( $r->{second_factor} ) {
        push @EXTRA, Lazysite::Odoo::Session::set_pending_header( $r->{pending_cookie}, _cookie_scope() );
        return reply( '200 OK', { ok => 1, signed_in => 0, second_factor => $r->{second_factor},
                remember_offered => ( $r->{remember_offered} ? 1 : 0 ) } );
    }
    push @EXTRA, Lazysite::Odoo::Session::set_cookie_header( $r->{cookie}, _cookie_scope() );
    _identity_cookie_out( $r->{identity_cookie} );
    _site_cookie_out($r);
    return reply( '200 OK', { ok => 1, signed_in => 1, identity => $r->{identity} } );
}

# SM1160: the site session's cookies, when the sign-in made one. A site session the browser
# already held (another person's, a stale one) is ended first, so a sign-in never leaves two.
sub _site_cookie_out {
    my ($r) = @_;
    return unless defined $r->{site_cookie};
    _end_site_session('replaced by a new sign-in');
    require Lazysite::Auth::Session;
    push @EXTRA, Lazysite::Auth::Session::odoo_cookie_headers( $r->{site_cookie},
        secure => ( $ENV{HTTPS} ? 1 : 0 ), dir => Lazysite::Paths::lazysite_dir( $ENV{DOCUMENT_ROOT} ) );
    return;
}

# SM1157: the second request of a two-factor sign-in. The code is the one thing in
# the body that is never logged, echoed or stored, as the password is not; the
# device value Odoo hands back for "remember this device" goes into its own cookie
# (HttpOnly, Secure, SameSite=Strict, this endpoint's path) and into no body, store
# or record. A wrong code leaves the pending cookie alone so the person can try
# again; a pending sign-in that has lapsed clears it and asks for the password.
sub _signin_code {
    my ( $req, %who ) = @_;
    my %ctx = ( mode => 'public', visitor_key => $who{visitor} );
    return _csrf_refusal( \%ctx ) unless _csrf_ok( \%ctx, $req );
    return reply( '400 Bad Request', { ok => 0, kind => 'invalid', error => 'a code is required' } )
        if ref $req->{code};    # remember may be a JSON boolean
    my $r = _timed( sub {
            Lazysite::Odoo::sign_in_code( pending_session => $who{pending}, code => $req->{code},
                remember => ( $req->{remember} ? 1 : 0 ), user_agent => $ENV{HTTP_USER_AGENT},
                ip => $who{ip}, secure => ( $ENV{HTTPS} ? 1 : 0 ) );
    } );
    unless ( $r->{ok} ) {
        push @EXTRA, Lazysite::Odoo::Session::clear_pending_header( _cookie_scope() ) if $r->{clear_pending};
        return refuse($r);
    }
    push @EXTRA, Lazysite::Odoo::Session::set_cookie_header( $r->{cookie}, _cookie_scope() );
    push @EXTRA, Lazysite::Odoo::Session::clear_pending_header( _cookie_scope() );
    if ( defined $r->{trusted_device} ) {
        my $h = Lazysite::Odoo::Session::set_device_header( $r->{trusted_device}, _cookie_scope() );
        push @EXTRA, $h if defined $h;
    }
    _identity_cookie_out( $r->{identity_cookie} );
    _site_cookie_out($r);
    return reply( '200 OK', { ok => 1, signed_in => 1, identity => $r->{identity} } );
}

# B: sign out. Ends the session at Odoo and clears the cookie; a person with no
# session is told ok all the same.
sub _signout {
    my ( $req, %who ) = @_;
    my %ctx = ( mode => 'public', visitor_key => $who{visitor} );
    return _csrf_refusal( \%ctx ) unless _csrf_ok( \%ctx, $req );
    _timed( sub { Lazysite::Odoo::sign_out( session_id => $who{odoo_session}, ip => $who{ip} ) } ) if $who{odoo_session};

    # SM1157: and a half-open two-factor sign-in the person gave up on
    if ( $who{pending} ) {
        _timed( sub { Lazysite::Odoo::sign_out( session_id => $who{pending}, ip => $who{ip} ) } );
        push @EXTRA, Lazysite::Odoo::Session::clear_pending_header( _cookie_scope() );
    }
    _clear_cookies();
    return reply( '200 OK', { ok => 1, signed_in => 0 } );
}

sub _writes {
    my ($b) = @_;
    my $w = eval {
        my ($conn) = Lazysite::Odoo::connection();
        # Cannot ask: let the call refuse, with the reason it has.
        return 0 unless $conn && ( Lazysite::Odoo::oom_check() )[0];
        my ($class) = Lazysite::Odoo::operation_class( $conn, $b->{operation} );
        $class ? ( $class->writes ? 1 : 0 ) : 0;
    };
    return $w // 0;
}

# SM929: the visitor's address, not the front proxy's.
sub _ip {
    my ($docroot) = @_;
    require Lazysite::Util;
    return Lazysite::Util::request_address(
        Lazysite::Util::trusted_proxy_spec( Lazysite::Paths::lazysite_dir($docroot) ) ) // '';
}

1;
