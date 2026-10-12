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
#                                and, for a signed-in account, the session one
#   GET  ?binding=ID&field=v...  run a READ binding
#   POST {binding, params}       run a binding (a write plans, or applies when
#                                the binding says immediate)
#   POST {plan, confirm: true}   apply a plan this caller made
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
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
}

exit main() if !caller;

# Headers set for this response before the body - the visitor cookie, when one
# is minted. Reset at the top of every request.
our @EXTRA;

sub reply {
    my ( $status, $data ) = @_;
    my $body = JSON::PP->new->utf8->canonical->encode($data);
    binmode STDOUT;
    print "Status: $status\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n";
    # What a visitor sees depends on who they are: never cached by anything.
    print "Cache-Control: no-store\r\n";
    print "$_\r\n" for @EXTRA;
    print 'Content-Length: ' . length($body) . "\r\n\r\n";
    print $body;
    return 0;
}

# A refusal's status comes from its kind, by the one map every surface uses.
sub refuse {
    my ($r) = @_;
    require Lazysite::Manager::Common;
    return reply( Lazysite::Manager::Common::refusal_status( $r->{kind} ), $r );
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

sub main {
    local @EXTRA = ();
    my $docroot = $ENV{DOCUMENT_ROOT} // '';
    return reply( '500 Internal Server Error', { ok => 0, error => 'no document root' } )
        unless length $docroot && -d $docroot;
    my $method = $ENV{REQUEST_METHOD} // 'GET';
    return reply( '405 Method Not Allowed',
        { ok => 0, error => 'this endpoint takes GET to read and POST to change' } )
        unless $method eq 'GET' || $method eq 'POST';

    no warnings 'once';
    require Lazysite::Manager::Plugins;
    require Lazysite::Paths;
    local $Lazysite::Manager::Plugins::DOCROOT = $docroot;
    return reply( '403 Forbidden',
        { ok => 0, kind => 'disabled',
            error => 'The Odoo extension is disabled. A sysop can enable it on the Extensions page.' } )
        unless Lazysite::Manager::Plugins::plugin_enabled('plugins/odoo.pl');

    require Lazysite::Odoo;
    require Lazysite::Odoo::Visitor;
    local $Lazysite::Odoo::DOCROOT          = $docroot;
    local $Lazysite::Odoo::Visitor::DOCROOT = $docroot;

    # THE IDENTITY, verified here.
    require Lazysite::Auth::Session;
    local $Lazysite::Auth::Session::LAZYSITE_DIR = Lazysite::Paths::lazysite_dir($docroot);
    my ($session) = Lazysite::Auth::Session::verify_session_cookie();
    my $user = ( ref $session eq 'HASH' ) ? ( $session->{user} // '' ) : '';
    my @groups;
    my $caps = {};
    if ( length $user ) {
        my $g = $session->{groups};
        @groups = grep { length } ( ref $g eq 'ARRAY' ? @$g : split /\s*,\s*/, ( $g // '' ) );
        require Lazysite::Auth::Settings;
        local $Lazysite::Auth::Settings::AUTH_DIR = Lazysite::Paths::lazysite_dir($docroot) . '/auth';
        $caps = Lazysite::Auth::Settings::caps_for($user) || {};
    }
    my $visitor = Lazysite::Odoo::Visitor::key_from_cookie( $ENV{HTTP_COOKIE} // '' );
    my $ip      = _ip($docroot);

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
        return reply( '200 OK',
            { ok => 1, visitor_token => Lazysite::Odoo::Visitor::csrf_token($visitor),
                ( length $user ? ( token => Lazysite::Auth::Session::generate_csrf_token($user) ) : () ) } );
    }

    my %who = ( user => $user, groups => \@groups, caps => $caps, visitor => $visitor, ip => $ip );

    if ( $method eq 'GET' ) {
        my $id = delete $q->{binding};
        my ( $b, $why ) = Lazysite::Odoo::find_binding($id);
        return refuse( { ok => 0, kind => 'not-found', error => $why } ) unless $b;
        return reply( '405 Method Not Allowed',
            { ok => 0, kind => 'method', error => 'this binding changes data - send it as a POST with its token' } )
            if _writes($b);
        return _answer( Lazysite::Odoo::call( $b, $q, _ctx( $b, %who ), strict => 1 ) );
    }

    my $len = $ENV{CONTENT_LENGTH} || 0;
    return reply( '413 Payload Too Large', { ok => 0, kind => 'too-large', error => 'body too large' } )
        if $len > 64 * 1024;
    my $raw = '';
    read( STDIN, $raw, $len ) if $len;
    my $req = eval { JSON::PP->new->utf8->decode($raw) };
    return reply( '400 Bad Request', { ok => 0, kind => 'invalid', error => 'the body must be a JSON object' } )
        unless ref $req eq 'HASH';

    if ( $req->{confirm} ) {
        # A confirm names no binding: which binding, and so which mode, is the
        # plan's. The caller's token must fit what the caller is.
        my %ctx = _ctx( undef, %who );
        return _csrf_refusal( \%ctx ) unless _csrf_ok( \%ctx, $req );
        return _answer( Lazysite::Odoo::confirm( $req->{plan}, %ctx ) );
    }

    my ( $b, $why ) = Lazysite::Odoo::find_binding( $req->{binding} );
    return refuse( { ok => 0, kind => 'not-found', error => $why } ) unless $b;
    my %ctx = _ctx( $b, %who );
    return _csrf_refusal( \%ctx ) unless _csrf_ok( \%ctx, $req );
    return reply( '400 Bad Request', { ok => 0, kind => 'invalid', error => 'params must be an object' } )
        if defined $req->{params} && ref $req->{params} ne 'HASH';
    return _answer( Lazysite::Odoo::call( $b, $req->{params} // {}, %ctx, strict => 1 ) );
}

# The call's context: authenticated where the account is verified and the
# binding admits that mode (or, for a confirm, always - the plan's owner check
# is what decides); public otherwise. The visitor key travels as the key, and
# the engine turns it into a hash before anything is recorded.
sub _ctx {
    my ( $b, %w ) = @_;
    my $authn = length $w{user} && ( !$b || $b->{modes}{authenticated} );
    return (
        mode   => ( $authn ? 'authenticated' : 'public' ),
        actor  => ( $authn ? $w{user}        : '' ),
        groups => $w{groups},
        caps   => $w{caps},
        ip     => $w{ip},
        ( $w{visitor} ? ( visitor_key => $w{visitor} ) : () ),
    );
}

sub _csrf_ok {
    my ( $ctx, $req ) = @_;
    if ( $ctx->{mode} eq 'authenticated' ) {
        my $t = $ENV{HTTP_X_CSRF_TOKEN} // $req->{token} // '';
        return Lazysite::Auth::Session::verify_csrf_token( $t, $ctx->{actor} );
    }
    return Lazysite::Odoo::Visitor::verify_csrf( $req->{visitor_token} // '', $ctx->{visitor_key} );
}

sub _csrf_refusal {
    my ($ctx) = @_;
    return reply( '403 Forbidden',
        { ok => 0, kind => 'csrf',
            error => ( $ctx->{mode} eq 'public' && !$ctx->{visitor_key} )
            ? 'no visitor key on this request - fetch tokens from ?csrf=1 first'
            : 'missing or stale token - fetch fresh ones from ?csrf=1 and retry' } );
}

sub _answer {
    my ($r) = @_;
    return refuse($r) unless $r->{ok};
    return reply( '200 OK', $r );
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
