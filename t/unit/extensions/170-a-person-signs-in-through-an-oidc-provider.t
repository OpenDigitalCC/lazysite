#!/usr/bin/perl
# SM1351 (rulings 185, 186, 206): A PERSON SIGNS IN THROUGH AN OUTSIDE OPENID
# CONNECT PROVIDER, WITH ITS GROUPS.
#
# A fixture issuer on 127.0.0.1 is two providers (p1, p2), each with its own
# discovery, authorisation, token and userinfo endpoints and its own client. The
# OIDC extension is enabled on a fixture site through the real manager, its
# config saved (which fetches discovery), its secrets set from the command line,
# and every sign-in driven through the real endpoint (lazysite-oidc.pl), the real
# session verifier and the real processor:
#
#   * a full sign-in: the start sends the browser to the provider with a state,
#     a nonce and an S256 challenge; the provider's answer is exchanged with the
#     client's secret and the PKCE verifier; the session is core's, oidc-p1:<sub>;
#   * refused, and no session: a state that is not the cookie's; no state cookie;
#     an ID token for another issuer (iss), another client (aud), with another
#     nonce, or expired; a person in no mapped group;
#   * ruling 186: a provider group mapped to operators (a group that carries a
#     capability) is granted, and the sign-in is audited with the groups granted;
#   * two providers side by side, each its own prefix, both offered on /login;
#   * ruling 206: a provider whose secret is gone is refused at the start, its
#     sessions end, /login stops offering it and `lazysite check` names it with
#     the remedy, while the other provider still signs people in; a discovery that
#     fails at refresh refuses that provider only;
#   * groups the ID token does not carry are read from userinfo;
#   * core: a provider id inside an instances provider's family is refused;
#   * ruling 213: a provider's CA bundle (`<name>.ca_file`) that cannot be read
#     refuses it, named with its remedy by the log and the check; a readable one
#     is that provider's client's SSL_ca_file and no other's; starts are
#     throttled per address by the sign-in limiter, and one over the limit writes
#     no pending record;
#   * ruling 214 (Q128): the Sessions page's "require sign-in again" marks a
#     session, which is then stale; a protected page sends it to the renew path
#     with next; the same person renews the same session, its groups read
#     afresh; another person gets their own; a local session is signed out.
#
# Sabotage (each run by hand, each fails here): drop the iss, aud or nonce check
# from check_claims; drop the const_eq of the state cookie in callback; drop
# `grants => 1` from the descriptor (the operators group is then dropped); drop
# the `instances` resolution from Hooks::identity_provider (no session verifies);
# drop the ca_file check from usable, or the SSL_ca_file from _ua; drop the
# limiter from start; ignore the mark in the verifier, keep it on renewal,
# always revoke, drop the session-reauth audit act, drop the renewal sid, or
# renew for anyone.
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use JSON::PP       qw(decode_json encode_json);
use Digest::SHA    qw(sha256);
use MIME::Base64   qw(encode_base64 decode_base64);
use HTTP::Daemon;
use HTTP::Response;
use LWP::UserAgent;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir run_child run_processor grant_caps add_account link_engine_extensions);
use ManagerSession                ();
use Lazysite::Manager::Extensions qw(action_extension_enable action_extension_save);
use Lazysite::Extensions::Hooks   qw(cross_problems);
use Lazysite::Auth::Session       ();

$ENV{LAZYSITE_LOG_LEVEL} = 'INFO';
my $root = repo_root();

sub spit { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $s = <$fh>; close $fh; return $s }
sub b64u { ( my $s = encode_base64( $_[0], '' ) ) =~ tr{+/}{-_}; $s =~ s/=+\z//; return $s }

sub form_of {
    my ($s) = @_;
    my %f;
    for ( split /&/, $s // '' ) {
        my ( $k, $v ) = split /=/, $_, 2;
        for ( $k, $v ) { next unless defined; tr/+/ /; s/%([0-9A-Fa-f]{2})/chr hex $1/ge }
        $f{$k} = $v // '';
    }
    return \%f;
}

# --- the fixture issuer ------------------------------------------------------
my $S = File::Temp::tempdir( CLEANUP => 1 );
make_path("$S/codes");
my $srv = HTTP::Daemon->new( LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1 ) or die "no daemon: $!";
( my $BASE = $srv->url ) =~ s{/\z}{};
my %CLIENT = ( p1 => [ 'site-one', 'secret-one' ], p2 => [ 'site-two', 'secret-two' ] );
my %HELD   = ( p1 => ['service-team'], p2 => ['partners'] );

sub mode { my ($p) = @_; ( my $m = slurp("$S/mode-$p") ) =~ s/\s+\z//; return length $m ? $m : 'good' }

sub answer {
    my ( $req, $p, $what ) = @_;
    my $iss  = "$BASE/$p";
    my $mode = mode($p);
    my $json = sub { my ( $code, $d ) = @_; my $r = HTTP::Response->new($code);
        $r->header( 'Content-Type' => 'application/json' ); $r->content( encode_json($d) ); return $r };
    if ( $what eq '.well-known/openid-configuration' ) {
        return HTTP::Response->new( 503, 'down' ) if $mode eq 'disc-down';
        return $json->( 200, { issuer => $iss, authorization_endpoint => "$iss/authorize",
                token_endpoint => "$iss/token", userinfo_endpoint => "$iss/userinfo",
                code_challenge_methods_supported      => ['S256'],
                token_endpoint_auth_methods_supported => ['client_secret_basic'] } );
    }
    if ( $what =~ /\Aauthorize\b/ ) {
        my $q    = form_of( $req->uri->query );
        my $code = 'code' . int( rand 1e9 );
        spit( "$S/codes/$code.json", encode_json( { %$q, p => $p } ) );
        my $r = HTTP::Response->new(302);
        $r->header( Location => "$q->{redirect_uri}?code=$code&state=$q->{state}" );
        return $r;
    }
    if ( $what eq 'token' ) {
        my $f = form_of( $req->content );
        my ( $id, $secret ) = @{ $CLIENT{$p} };
        my $auth = $req->header('Authorization') // '';
        return $json->( 401, { error => 'invalid_client' } )
            unless $auth eq 'Basic ' . encode_base64( "$id:$secret", '' );
        my $cf  = "$S/codes/" . ( $f->{code} // 'x' ) . '.json';
        my $rec = -f $cf ? decode_json( slurp($cf) ) : undef;
        unlink $cf;
        return $json->( 400, { error => 'invalid_grant' } )
            unless $rec && $rec->{p} eq $p && ( $f->{redirect_uri} // '' ) eq $rec->{redirect_uri}
            && b64u( sha256( $f->{code_verifier} // '' ) ) eq $rec->{code_challenge}
            && $rec->{code_challenge_method} eq 'S256' && $rec->{client_id} eq $id;
        my %c = ( iss => $iss, aud => $id, sub => 'user-123', email => 'pat@example.com', nonce => $rec->{nonce},
            exp => time + 300, iat => time, groups => $HELD{$p} );
        $c{iss}    = 'https://evil.example/' if $mode eq 'bad-iss';
        $c{aud}    = 'another-client'        if $mode eq 'bad-aud';
        $c{nonce}  = 'not-the-nonce'         if $mode eq 'bad-nonce';
        $c{exp}    = time - 3600             if $mode eq 'expired';
        $c{groups} = ['nobody-maps-this']    if $mode eq 'no-group';
        delete $c{groups} if $mode eq 'userinfo';
        $c{groups} = ['writers'] if $mode eq 'writer';
        $c{sub}    = 'user-999'  if $mode eq 'other';
        my $jwt = join '.', b64u( encode_json( { alg => 'RS256' } ) ), b64u( encode_json( \%c ) ), b64u('not-checked');
        return $json->( 200, { id_token => $jwt, access_token => "at-$p", token_type => 'Bearer' } );
    }
    if ( $what eq 'userinfo' ) {
        return $json->( 401, { error => 'invalid_token' } ) unless ( $req->header('Authorization') // '' ) eq "Bearer at-$p";
        return $json->( 200, { sub => 'user-123', groups => $HELD{$p} } );
    }
    return HTTP::Response->new(404);
}

my $pid = fork;
die "fork: $!" unless defined $pid;
if ( !$pid ) {
    while ( my $conn = $srv->accept ) {
        while ( my $req = $conn->get_request ) {
            my ( $p, $what ) = $req->uri->path =~ m{\A/(p[12])/(.+)\z};
            $conn->send_response( defined $p ? answer( $req, $p, $what ) : HTTP::Response->new(404) );
        }
        $conn->close;
    }
    exit 0;
}
END { kill 'TERM', $pid if $pid }

# --- the site ----------------------------------------------------------------
my $D = site_tempdir();
system( 'cp', '-r', "$root/starter/.", $D ) == 0 or die 'copy starter';
my $LZ = "$D/lazysite";
make_path( "$LZ/auth", "$LZ/logs", "$LZ/cache" );
spit( "$LZ/lazysite.conf", "site_name: T\n" );
spit( "$LZ/auth/.secret",  ( 'c' x 64 ) . "\n" );
grant_caps( $D, 'boss', 'ui', 'manage_users' );    # a secured site; boss manages sessions
add_account( $D, 'boss' );
grant_caps( $D, 'boss', 'ui' );                    # a secured site
grant_caps( $D, 'operators', 'ui', 'api' );        # role-operators carries capabilities
link_engine_extensions($D);

spit( "$LZ/oidc.conf", join '', map { "$_\n" }
        "p1.issuer: $BASE/p1", 'p1.client_id: site-one', 'p1.group_map: service-team = role-operators',
    'p1.label: Sign in with One',
    "p2.issuer: $BASE/p2", 'p2.client_id: site-two', 'p2.group_map: partners = staff',
    'p2.label: Sign in with Two' );

sub secret_set {
    my ( $name, $value ) = @_;
    return run_child( [ $^X, "$root/extensions/oidc.pl", '--secret', $name, '--docroot', $D ],
        stdin => "$value\n", stderr => 'discard' );
}

no warnings 'once';
$Lazysite::Manager::Extensions::DOCROOT = $D;
my $en = action_extension_enable('extensions/oidc.pl');
ok( $en->{ok} && grep( { $_ eq 'oidc' } @{ $en->{index}{indexed} || [] } ), 'the extension is enabled and indexed' )
    or diag explain $en;
is( secret_set( 'p1', 'secret-one' )->{status}, 0, 'the secret of p1 is set from the command line' );
is( secret_set( 'p2', 'secret-two' )->{status}, 0, '...and of p2' );
unlike( slurp("$LZ/oidc.conf"), qr/secret-/, 'neither secret is in the config file' );
my $sv = action_extension_save( undef, 'extensions/oidc.pl', { providers => [
            { name => 'p1', issuer => "$BASE/p1", client_id => 'site-one', group_map => [ [ 'service-team', 'role-operators' ] ],
                label => 'Sign in with One' },
            { name => 'p2', issuer => "$BASE/p2", client_id => 'site-two', group_map => 'partners = staff',
                label => 'Sign in with Two' } ] } );
ok( $sv->{ok} && $sv->{hook} && $sv->{hook}{ok}, 'saving the config fetches each provider\'s discovery' )
    or diag explain $sv;

# --- driving a browser ---------------------------------------------------------
sub cgi {
    my (%e) = @_;
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_COOKIE CONTENT_LENGTH HTTPS)};
    %ENV = ( %ENV, DOCUMENT_ROOT => $D, REQUEST_METHOD => 'GET', HTTP_HOST => 'site.test',
        REMOTE_ADDR => '192.0.2.10', %e );
    my $r = run_child( [ $^X, "$root/lazysite-oidc.pl" ] );
    my ( $head, $body ) = split /\r\n\r\n/, $r->{out}, 2;
    my ($status) = ( $head // '' ) =~ /^Status:\s*(\d+)/m;
    my ($loc)    = ( $head // '' ) =~ /^Location:\s*(\S+)/m;
    my @cookies  = ( $head // '' ) =~ /^Set-Cookie:\s*([^\r\n]+)/mg;
    return { status => $status // 0, location => $loc, cookies => \@cookies, body => $body // '', log => $r->{err} };
}

sub cookie_value {
    my ( $r, $name ) = @_;
    for ( @{ $r->{cookies} } ) { return $1 if /\A\Q$name\E=([^;]*)/ && length $1 }
    return undef;
}

my $UA = LWP::UserAgent->new( max_redirect => 0 );

# Start, go to the provider, come back: ( start, callback ). %o: cookie => a
# state cookie to send instead of the one the start set, no_cookie => 1.
sub sign_in {
    my ( $p, %o ) = @_;
    my $s = cgi( QUERY_STRING => "provider=$p&next=/dash" );
    return ( $s, undef ) unless $s->{status} == 302;
    my $at = $UA->get( $s->{location} );
    my $q  = form_of( ( URI->new( $at->header('Location') // '' )->query ) );
    my $st = cookie_value( $s, 'lzs_oidc_state' );
    my $ck = $o{no_cookie} ? undef : $o{cookie} // $st;
    my $c  = cgi( QUERY_STRING => "code=$q->{code}&state=$q->{state}",
        ( defined $ck ? ( HTTP_COOKIE => "lzs_oidc_state=$ck" ) : () ) );
    return ( $s, $c );
}

# In a process of its own, as each request is: the hook loader then loads the
# extension's module from the site's payload and nowhere else.
my $VERIFY = 'local $Lazysite::Auth::Session::LAZYSITE_DIR = $ARGV[0];'
    . ' print JSON::PP->new->canonical->encode( [ Lazysite::Auth::Session::verify_session_cookie() ] )';

sub verify {
    my ($cookie) = @_;
    local $ENV{HTTP_COOKIE} = "lazysite_auth=$cookie";
    my $r = run_child( [ $^X, "-I$root/lib", '-MJSON::PP', '-MLazysite::Auth::Session', '-e', $VERIFY, $LZ ],
        stderr => 'discard' );
    my $out = eval { decode_json( $r->{out} ) } or return ( undef, "the verifier answered: $r->{out}" );
    return @$out;
}

sub set_mode { my ( $p, $m ) = @_; spit( "$S/mode-$p", $m ); return }

# ---------------------------------------------------------------------------
my $P1;
subtest 'a full sign-in through a provider' => sub {
    my ( $s, $c ) = sign_in('p1');
    is( $s->{status}, 302, 'the start sends the browser on' );
    like( $s->{location}, qr{\A\Q$BASE\E/p1/authorize\?}, '...to the provider\'s authorisation endpoint' );
    my $q = form_of( URI->new( $s->{location} )->query );
    is( $q->{client_id},             'site-one', 'naming this site\'s client' );
    is( $q->{code_challenge_method}, 'S256',     'with a PKCE S256 challenge' );
    like( $q->{state}, qr/\A[0-9a-f]{64}\z/, 'a state' );
    ok( length $q->{nonce}, 'a nonce' );
    is( $q->{redirect_uri}, 'http://site.test/cgi-bin/lazysite-oidc.pl', 'and the endpoint as the redirect URI' );
    is( cookie_value( $s, 'lzs_oidc_state' ), $q->{state}, 'the state is this browser\'s cookie' );
    is( $c->{status}, 302, 'the provider\'s answer signs the person in' ) or diag $c->{body}, $c->{log};
    is( $c->{location}, '/dash', '...and goes on to where they were going' );
    $P1 = cookie_value( $c, 'lazysite_auth' );
    ok( $P1, 'a session cookie is set' );
    my ( $id, $why ) = verify($P1);
    my @all = verify($P1);
    ok( $id, 'the session verifies' ) or diag explain \@all;
    is( $id->{user},     'oidc-p1:user-123', 'as oidc-<provider>:<sub>' );
    is( $id->{provider}, 'oidc-p1',          'naming the provider' );
    is( $id->{name},     'pat@example.com',  'shown by the email' );
};

subtest 'ruling 186: a group mapped to operators is granted, and audited' => sub {
    my ($id) = verify($P1);
    is( $id->{groups}, 'role-operators', 'the capability-carrying group is granted' );
    my ($row) = grep { /login-grant/ } split /\n/, slurp("$LZ/logs/audit.log");
    ok( $row, 'the sign-in is audited' );
    like( $row // '', qr/oidc-p1:user-123/, '...with the provider and the subject' );
    like( $row // '', qr/groups granted: role-operators/, '...and the groups it granted' );
};

subtest 'refused: the state, the issuer, the audience, the nonce, the expiry' => sub {
    my ( undef, $c ) = sign_in( 'p1', cookie => 'f' x 64 );
    is( $c->{status}, 403, 'a state that is not the cookie\'s: refused' );
    ok( !cookie_value( $c, 'lazysite_auth' ), '...and no session' );
    ( undef, $c ) = sign_in( 'p1', no_cookie => 1 );
    is( $c->{status}, 403, 'no state cookie: refused' );
    for my $m (qw(bad-iss bad-aud bad-nonce expired)) {
        set_mode( 'p1', $m );
        ( undef, $c ) = sign_in('p1');
        is( $c->{status}, 403, "$m: refused" );
        ok( !cookie_value( $c, 'lazysite_auth' ), "$m: no session" );
    }
    set_mode( 'p1', 'no-group' );
    ( undef, $c ) = sign_in('p1');
    is( $c->{status}, 403, 'a person in no mapped group: refused, no account made' );
    ok( !cookie_value( $c, 'lazysite_auth' ), '...and no session' );
    set_mode( 'p1', 'good' );
};

my $P2;
subtest 'two providers side by side' => sub {
    my ( undef, $c ) = sign_in('p2');
    $P2 = cookie_value( $c, 'lazysite_auth' );
    my ($id) = verify( $P2 // '' );
    is( $id->{user},   'oidc-p2:user-123', 'p2 signs in under its own prefix' );
    is( $id->{groups}, 'staff',            'with its own map' );
    is( ( verify($P1) )[0]{user}, 'oidc-p1:user-123', 'p1\'s session stands beside it' );
    my $login = run_processor( $D, '/login', QUERY_STRING => 'next=/dash' );
    like( $login, qr{class="login-oidc-p1".*href="/cgi-bin/lazysite-oidc\.pl\?provider=p1&amp;next=%2Fdash">Sign in with One<}s,
        '/login offers p1, carrying next' );
    like( $login, qr{class="login-oidc-p2".*>Sign in with Two<}s, '...and p2' );
};

subtest 'userinfo: groups the ID token does not carry' => sub {
    set_mode( 'p2', 'userinfo' );
    my ( undef, $c ) = sign_in('p2');
    my ($id) = verify( cookie_value( $c, 'lazysite_auth' ) // '' );
    is( $id->{groups}, 'staff', 'the groups are read from the userinfo endpoint' );
    set_mode( 'p2', 'good' );
};

subtest 'ruling 214 (Q128): require sign-in again' => sub {
    my $m = bless { docroot => $D, root => $root, users => "$root/tools/lazysite-users.pl",
        api => "$root/lazysite-manager-api.pl" }, 'ManagerSession';
    ( my $raw = $P1 ) =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
    my ($sid) = $raw =~ /\Aoidc-p1=[^:]+:\d+:([0-9a-f]{16}):/ or die "no sid in $raw";
    my $conf  = slurp("$LZ/oidc.conf");
    spit( "$LZ/oidc.conf", $conf =~ s/^p1\.group_map: .*$/p1.group_map: service-team = role-operators, writers = staff/mr );
    my $r = $m->call( 'boss', 'session-revoke', body => { sid => $sid, reauth => JSON::PP::true() }, groups => 'role-boss' );
    ok( $r->{ok} && $r->{reauth}, 'the Sessions page marks the session' ) or diag explain $r;
    is( $r->{provider}, 'oidc-p1', '...as a provider\'s' );
    like( slurp("$LZ/logs/audit.log"), qr/\| session-reauth \| sid:\Q@{[ substr $sid, 0, 8 ]}\E \|.*provider=oidc-p1/,
        '...with an audit row of its own' );
    my ( $id, $why, %d ) = verify($P1);
    ok( !$id, 'the session is no identity until it signs in again' );
    is( $why, 'oidc-p1-stale', '...refused as stale' );
    spit( "$D/members.md", "---\ntitle: Members\nauth: required\n---\nMEMBERS-ONLY\n" );
    my $page = run_processor( $D, '/members', HTTP_COOKIE => "lazysite_auth=$P1" );
    like( $page, qr{^Location: /cgi-bin/lazysite-oidc\.pl\?renew=1&next=%2Fmembers}m,
        'a protected page sends it to its provider\'s endpoint, with next' );
    set_mode( 'p1', 'writer' );
    my $s = cgi( QUERY_STRING => 'renew=1&next=/members', HTTP_COOKIE => "lazysite_auth=$P1" );
    diag $s->{log} unless ( $s->{status} // 0 ) == 302 && ( $s->{location} // "" ) =~ /authorize/;
    is( $s->{status}, 302, 'the endpoint starts a sign-in' );
    like( $s->{location} // '', qr{\A\Q$BASE\E/p1/authorize\?}, '...at the same provider' );
    my $at = $UA->get( $s->{location} );
    my $q  = form_of( URI->new( $at->header('Location') // '' )->query );
    my $c  = cgi( QUERY_STRING => "code=$q->{code}&state=$q->{state}",
        HTTP_COOKIE => 'lzs_oidc_state=' . cookie_value( $s, 'lzs_oidc_state' ) . "; lazysite_auth=$P1" );
    is( $c->{status}, 302, 'the person signs in again' ) or diag $c->{body}, $c->{log};
    is( $c->{location}, '/members', '...and is returned to the page they asked for' );
    ok( !cookie_value( $c, 'lazysite_auth' ), '...keeping the session they had' );
    ($id) = verify($P1);
    is( $id->{user},   'oidc-p1:user-123', 'the same session is an identity again' );
    is( $id->{groups}, 'staff',            '...with the groups read afresh' );
    set_mode( 'p1', 'good' );
    spit( "$LZ/oidc.conf", $conf );

    # Someone else signing in at the prompt gets a session of their own.
    $r = $m->call( 'boss', 'session-revoke', body => { sid => $sid, reauth => JSON::PP::true() }, groups => 'role-boss' );
    set_mode( 'p1', 'other' );
    $s = cgi( QUERY_STRING => 'renew=1&next=/members', HTTP_COOKIE => "lazysite_auth=$P1" );
    $at = $UA->get( $s->{location} );
    $q  = form_of( URI->new( $at->header('Location') // '' )->query );
    $c  = cgi( QUERY_STRING => "code=$q->{code}&state=$q->{state}",
        HTTP_COOKIE => 'lzs_oidc_state=' . cookie_value( $s, 'lzs_oidc_state' ) . "; lazysite_auth=$P1" );
    my $other = cookie_value( $c, 'lazysite_auth' );
    ok( $other, 'another person signing in at the prompt gets a new session' );
    is( ( verify( $other // '' ) )[0]{user}, 'oidc-p1:user-999', '...as themselves' );
    is( ( verify($P1) )[1], 'oidc-p1-stale', '...and the marked session is not renewed for them' );
    set_mode( 'p1', 'good' );
    $s = cgi( QUERY_STRING => 'renew=1&next=/members', HTTP_COOKIE => "lazysite_auth=$P1" );
    $at = $UA->get( $s->{location} );
    $q  = form_of( URI->new( $at->header('Location') // '' )->query );
    cgi( QUERY_STRING => "code=$q->{code}&state=$q->{state}",
        HTTP_COOKIE => 'lzs_oidc_state=' . cookie_value( $s, 'lzs_oidc_state' ) . "; lazysite_auth=$P1" );
    is( ( verify($P1) )[0]{user}, 'oidc-p1:user-123', 'its own person renews it' );

    # A local session: signing in again is signing out.
    open my $reg, '>>', "$LZ/auth/sessions.jsonl" or die $!;
    print {$reg} JSON::PP->new->canonical->encode( { sid => 'abcdef0123456789', user => 'ed', t => time } ), "\n";
    close $reg;
    $r = $m->call( 'boss', 'session-revoke', body => { sid => 'abcdef0123456789', reauth => JSON::PP::true() }, groups => 'role-boss' );
    ok( $r->{ok} && $r->{reauth} && !$r->{provider}, 'a local session is marked too' ) or diag explain $r;
    like( slurp("$LZ/auth/revoked.json"), qr/abcdef0123456789/, '...by signing it out' );
};

subtest 'ruling 206: a broken secret refuses that provider only, and is named' => sub {
    unlink "$LZ/oidc/keys/p2.key" or die "unlink: $!";
    my $s = cgi( QUERY_STRING => 'provider=p2' );
    is( $s->{status}, 503, 'p2\'s start is refused' );
    like( $s->{log}, qr/client secret of 'p2' is not set/, '...the log names the fault' );
    like( $s->{log}, qr/fix=set the client secret: extensions\/oidc.pl --secret p2 /, '...and the remedy' );
    my ( $id, $why ) = verify($P2);
    ok( !$id, 'p2\'s session ends' );
    is( $why,                     'oidc-p2-off',      '...as its provider being off' );
    is( ( verify($P1) )[0]{user}, 'oidc-p1:user-123', 'p1\'s session is untouched' );
    my ( undef, $c ) = sign_in('p1');
    is( $c->{status}, 302, 'p1 still signs people in' );
    my $login = run_processor( $D, '/login' );
    unlike( $login, qr/login-oidc-p2/, '/login no longer offers p2' );
    like( $login, qr/login-oidc-p1/, '...and still offers p1' );
    my $st = run_child( [ $^X, "$root/extensions/oidc.pl", '--action', 'status', '--docroot', $D ], stderr => 'discard' );
    my $f    = eval { decode_json( $st->{out} ) } || {};
    my ($p2) = grep { $_->{text} =~ /provider p2/ } @{ $f->{findings} || [] };
    is( $p2->{level}, 'FAIL', 'lazysite check fails p2' );
    like( $p2->{fix} // '', qr/--secret p2/, '...naming the remedy' );
    my ($p1) = grep { $_->{text} =~ /provider p1/ } @{ $f->{findings} || [] };
    is( $p1->{level}, 'OK', '...and passes p1' );
    secret_set( 'p2', 'secret-two' );
};

subtest 'a discovery that fails refuses that provider only' => sub {
    set_mode( 'p1', 'disc-down' );
    my $r = run_child( [ $^X, "$root/extensions/oidc.pl", '--action', 'refresh', '--docroot', $D ], stderr => 'discard' );
    my $j = eval { decode_json( $r->{out} ) } || {};
    ok( !$j->{providers}{p1}{ok} && $j->{providers}{p2}{ok}, 'the refresh says p1 failed and p2 did not' );
    is( cgi( QUERY_STRING => 'provider=p1' )->{status}, 503, 'p1 is refused' );
    my ( undef, $c ) = sign_in('p2');
    is( $c->{status}, 302, 'p2 still signs people in' );
    set_mode( 'p1', 'good' );
    run_child( [ $^X, "$root/extensions/oidc.pl", '--action', 'refresh', '--docroot', $D ], stderr => 'discard' );
    is( cgi( QUERY_STRING => 'provider=p1' )->{status}, 302, 'a refresh that succeeds lets p1 sign people in again' );
};

subtest 'ruling 213: a provider\'s own CA bundle' => sub {
    my $conf = slurp("$LZ/oidc.conf");
    spit( "$LZ/oidc.conf", $conf . "p2.ca_file: $D/no-such-ca.pem\n" );
    my $s = cgi( QUERY_STRING => 'provider=p2' );
    is( $s->{status}, 503, 'a CA bundle that cannot be read refuses that provider' );
    like( $s->{log}, qr/why=p2\.ca_file '[^']+' is not a file/, '...naming the fault' );
    like( $s->{log}, qr/fix=make p2\.ca_file name a PEM file/,  '...and the remedy' );
    my $st = run_child( [ $^X, "$root/extensions/oidc.pl", '--action', 'status', '--docroot', $D ], stderr => 'discard' );
    my $f    = eval { decode_json( $st->{out} ) } || {};
    my ($p2) = grep { $_->{text} =~ /provider p2/ } @{ $f->{findings} || [] };
    is( $p2->{level}, 'FAIL', 'lazysite check fails p2' );
    like( $p2->{fix} // '', qr/p2\.ca_file/, '...naming the remedy' );
    is( cgi( QUERY_STRING => 'provider=p1' )->{status}, 302, 'p1 is untouched' );
    spit( "$D/ca.pem",     "-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----\n" );
    spit( "$LZ/oidc.conf", $conf . "p2.ca_file: $D/ca.pem\n" );
    is( cgi( QUERY_STRING => 'provider=p2' )->{status}, 302, 'a readable bundle: p2 starts again' );
    my $ua = run_child( [ $^X, "-I$root/lib", "-I$root/extensions/oidc/lib", '-MLazysite::Ext::OIDC', '-e',
            'print Lazysite::Ext::OIDC::_ua( { ca_file => $ARGV[0] } )->ssl_opts("SSL_ca_file") // "", "|",'
                . ' Lazysite::Ext::OIDC::_ua( {} )->ssl_opts("SSL_ca_file") // ""', "$D/ca.pem" ], stderr => 'discard' );
    is( $ua->{out}, "$D/ca.pem|", 'the bundle is the client\'s SSL_ca_file for that provider, and for no other' );
    spit( "$LZ/oidc.conf", $conf );
};

subtest 'ruling 213: starts are throttled per address, and write nothing over the limit' => sub {
    my $rl = action_extension_enable('extensions/login-rate-limit.pl');
    ok( $rl->{ok}, 'the sign-in limiter is on' ) or diag explain $rl;
    my $pending = sub { opendir my $dh, "$LZ/oidc/pending" or return 0; my $n = grep { /\.json\z/ } readdir $dh; return $n };
    my @st = map { cgi( QUERY_STRING => 'provider=p1', REMOTE_ADDR => '198.51.100.7' )->{status} } 1 .. 5;
    is_deeply( \@st, [ (302) x 5 ], 'five starts from one address are let through' );
    my $before = $pending->();
    my $over   = cgi( QUERY_STRING => 'provider=p1', REMOTE_ADDR => '198.51.100.7' );
    is( $over->{status}, 429,     'the sixth is refused' );
    is( $pending->(),    $before, '...and writes no pending record' );
    is( cgi( QUERY_STRING => 'provider=p1', REMOTE_ADDR => '198.51.100.8' )->{status}, 302,
        'another address is not held back' );
};

subtest 'core: no provider id inside an instances provider\'s family' => sub {
    my %ip  = ( on => 'P::on', still_valid => 'P::still_valid', groups => 'P::groups' );
    my %bad = cross_problems( {
            oidc      => { hooks => { identity_provider => { %ip, instances => 1 } } },
            'oidc-p1' => { hooks => { identity_provider => {%ip} } },
            'oidcx'   => { hooks => { identity_provider => {%ip} } } } );
    like( join( ' ', @{ $bad{'oidc-p1'} || [] } ), qr/inside the extension 'oidc''s providers/, 'oidc-p1 is refused' );
    ok( !$bad{oidc} && !$bad{oidcx}, '...and nothing else' );
};

done_testing;
