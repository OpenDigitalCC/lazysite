package Lazysite::Ext::OIDC;

# SM1351: SIGN IN THROUGH AN OUTSIDE OPENID CONNECT PROVIDER, WITH ITS GROUPS.
#
# The OIDC extension is H-1's second consumer (SM1369 X4): an identity provider
# that core holds the sessions of. It is several providers at once (H-1's
# `instances`): each is named in lazysite/oidc.conf, and each is the provider
# `oidc-<name>` - its own session prefix, record, why codes and audit rows.
#
#   providers: corp, partner
#   corp.issuer: https://id.example.com/application/o/lazysite/
#   corp.client_id: lazysite-site
#   corp.scopes: openid email groups
#   corp.group_claim: groups
#   corp.group_map: service-team = operators, staff = editors
#   corp.label: Sign in with Example ID
#
# The client secret is in the one secrets store (Lazysite::Secrets, H-11) as
# lazysite/oidc/keys/<name>.key, set from the command line by
# `extensions/oidc.pl --secret <name> --docroot DIR` (it reads standard input),
# never in the config file.
#
# THE FLOW is the authorisation code flow with PKCE (S256), started and finished
# at /cgi-bin/lazysite-oidc.pl. The state is a random value in a cookie bound to
# this browser, and the record it names (the nonce, the PKCE verifier, the
# redirect URI and where to go next) is kept here, single use, for ten minutes.
#
# RULING 185: THE IDENTITY IS THE TOKEN ENDPOINT'S ANSWER, OVER TLS, TO A CLIENT
# THAT AUTHENTICATED (OpenID Connect Core 3.1.3.7, item 6). The ID token's
# signature is not checked, so there is no JWKS to fetch, cache or rotate. What is
# checked: the state (the cookie and the query agree, and name a record made here),
# then iss (the configured issuer, exactly), aud (the client id; with several
# audiences, azp is the client id), the nonce, and exp. sub, the email and the
# groups are read from the ID token, and from the userinfo endpoint (its sub the
# token's) for any the token does not carry.
#
# RULING 186: THE GROUPS MAY GRANT. The extension declares `grants`, so a provider
# group may map to a group that carries a capability, operators included; core
# audits every sign-in and renewal through it with the groups it granted (H-1's
# row). A person who maps to no group is not signed in: no account is made.
#
# RULING 206: A BROKEN PROVIDER IS REFUSED, NEVER GUESSED AROUND. A provider whose
# config is wrong (a missing issuer, a map entry that cannot be read), whose secret
# is absent or unreadable, or whose discovery could not be fetched signs nobody in,
# and its sessions end; the log and `lazysite check` name the fault and the
# remedy. The other providers are untouched. A config file that cannot be read
# refuses them all.
#
# DISCOVERY (/.well-known/openid-configuration) is fetched when the config is
# saved and by the Refresh action, and cached in lazysite/oidc/discovery/. A fetch
# that fails replaces the cache with the failure, so that provider is refused until
# a refresh succeeds - never signed in through an answer it no longer gives.
use strict;
use warnings;
use JSON::PP          ();
use Digest::SHA       qw(sha256 sha256_hex);
use MIME::Base64      qw(encode_base64 decode_base64);
use File::Path        qw(make_path);
use Lazysite::Util    qw(log_event cannot_read write_private_atomic const_eq);
use Lazysite::Secrets ();

our $ID          = 'oidc';
our $PENDING_TTL = 600;          # seconds a sign-in may take at the provider
our $SKEW        = 60;           # seconds of clock difference allowed on exp and iat
our $ANSWER_CAP  = 256 * 1024;
our $TIMEOUT     = 10;
our $ENDPOINT    = '/cgi-bin/lazysite-oidc.pl';

my $NAME  = qr/\A[a-z][a-z0-9]{0,15}\z/;
my $GROUP = qr/\A[A-Za-z0-9_-]{1,64}\z/;    # the session verifier's rule for a site group
my @KEYS  = qw(issuer client_id scopes group_claim group_map label ca_file);

# ---- the config ----

sub conf_path {
    my ($docroot) = @_;
    return undef unless defined $docroot && length $docroot;
    require Lazysite::Paths;
    my $lz = Lazysite::Paths::lazysite_dir($docroot) // return undef;
    return "$lz/oidc.conf";
}

# ( { name => provider }, '' ) or ( undef, why ). A file that is not there is no
# provider; one that is there and cannot be read is a fault for every provider.
sub providers {
    my ($docroot) = @_;
    my $path = conf_path($docroot) // return ( undef, 'the site has no document root' );
    my %kv;
    if ( open my $fh, '<:encoding(UTF-8)', $path ) {
        while ( my $l = <$fh> ) {
            $l =~ s/\A\s+|\s+\z//g;
            next if !length $l || $l =~ /\A#/;
            my ( $k, $v ) = split /\s*:\s*/, $l, 2;
            $kv{$k} = $v // '' if defined $k && length $k;
        }
        close $fh;
    }
    elsif ( !$!{ENOENT} ) {
        cannot_read( 'the OIDC config', $path );
        return ( undef, 'lazysite/oidc.conf exists and cannot be read by this process' );
    }
    my %out;
    for my $name ( grep { length } split /\s*,\s*/, ( $kv{providers} // '' ) ) {
        my %p   = ( name => $name, provider => "$ID-$name", problems => [] );
        my $bad = sub { push @{ $p{problems} }, $_[0]; return };
        if ( $name !~ $NAME ) {
            $bad->("'$name' is not a provider name: a lower-case letter, then letters and digits, at most 16");
            $out{$name} = \%p;
            next;
        }
        $p{$_}          = $kv{"$name.$_"} // '' for @KEYS;
        $p{scopes}      = 'openid email profile' unless length $p{scopes};
        $p{group_claim} = 'groups'               unless length $p{group_claim};
        $p{label}       = "Sign in with $name"   unless length $p{label};
        $bad->("$name.issuer is not set") unless length $p{issuer};
        $bad->("$name.issuer must be https:// (http:// only to 127.0.0.1 or localhost)")
            if length $p{issuer} && !url_ok( $p{issuer} );
        $bad->("$name.ca_file must be a full path to a PEM file") if length $p{ca_file} && $p{ca_file} !~ m{\A/[^\x00-\x1f\x7f]+\z};
        $bad->("$name.client_id is not set") unless length $p{client_id};
        $bad->("$name.client_id must be printable, with no space") if $p{client_id} =~ /[\s\x00-\x1f\x7f]/;
        $bad->("$name.scopes must include openid") unless grep { $_ eq 'openid' } split /\s+/, $p{scopes};
        $bad->("$name.scopes must be scope names separated by spaces") if $p{scopes} =~ /[^\w .:\/-]/;
        $bad->("$name.group_claim must be a claim name") unless $p{group_claim} =~ /\A[A-Za-z0-9_:.\/-]{1,64}\z/;
        $bad->("$name.label must be printable") if $p{label} =~ /[\x00-\x1f\x7f]/;
        my ( $map, $mwhy ) = parse_group_map( $p{group_map} );
        if ( defined $map ) { $p{map} = $map }
        else                { $bad->("$name.group_map: $mwhy") }
        $bad->("$name.group_map maps no group, so nobody could sign in") if defined $map && !%$map;
        $out{$name} = \%p;
    }
    return ( \%out, '' );
}

# 'provider group = site group, ...' -> ( { provider group => [ site groups ] } )
# or ( undef, why ). An entry that cannot be read refuses the whole map: half a
# map would sign people in with less, or more, than was meant.
sub parse_group_map {
    my ($s) = @_;
    my %map;
    for my $e ( grep { /\S/ } split /,/, ( $s // '' ) ) {
        my ( $from, $to ) = $e =~ /\A\s*([^=]*?)\s*=\s*([^=]*?)\s*\z/
            or return ( undef, "'$e' is not <provider group> = <site group>" );
        return ( undef, "'$e' names no provider group" ) unless length $from;
        return ( undef, "'$to' is not a site group name (letters, digits, _ and -)" ) unless $to =~ $GROUP;
        push @{ $map{$from} }, $to unless grep { $_ eq $to } @{ $map{$from} || [] };
    }
    return ( \%map );
}

# THE SETTINGS FORM'S CHECK OF A GROUP MAP (Manager::Extensions, a records
# field's validate): '' to keep it, else why not. Ruling 214 (Q129): a target that
# carries capabilities - operators, or any group that grants something - is
# saved only by an operator; a manage_config holder may map to plain groups, and
# keeps whatever capability targets the map already held. The refusal is
# `forbidden`, naming the group and why.
sub validate_group_map {
    my ( $value, $lz, $ctx ) = @_;
    my ( $map, $why ) = parse_group_map($value);
    return $why unless $map;
    $ctx = {}   unless ref $ctx eq 'HASH';
    return '' if $ctx->{operator};
    my ($had) = parse_group_map( $ctx->{old} // '' );
    my %had = map { $_ => 1 } map { @$_ } values %{ $had || {} };
    require Lazysite::Auth::Settings;
    no warnings 'once';
    local $Lazysite::Auth::Settings::AUTH_DIR = "$lz/auth";
    my %seen;
    for my $g ( grep { !$seen{$_}++ } map { @$_ } values %$map ) {
        next if $had{$g};
        my $cap = Lazysite::Auth::Settings::group_carries_capability($g);
        return { kind => 'forbidden',
            error => "$cap, so mapping a provider group to it would make the provider's members "
                . 'hold them here; only the operator may save that (ruling 214)' }
            if length $cap;
    }
    return '';
}

# The operator's choice of address, as a connector's: https:// to any host, plain
# http:// only to this host.
sub url_ok {
    my ($u) = @_;
    return 0 unless defined $u && !ref $u && $u !~ /[\s\x00-\x1f\x7f]/;
    return $u =~ m{\Ahttps://[^\s/?#]+} || $u =~ m{\Ahttp://(?:127\.0\.0\.1|localhost)(?::\d+)?(?:/|\z)} ? 1 : 0;
}

# ---- the store ----

sub _dir {
    my ( $lz, $sub ) = @_;
    my $d = "$lz/$ID/$sub";
    eval { make_path( $d, { mode => 0700 } ) unless -d $d; 1 } or return undef;
    return -d $d ? $d : undef;
}

sub _read_json {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return $!{ENOENT} ? ( undef, 'absent' ) : do {
        cannot_read( 'an OIDC record', $path );
        ( undef, 'unreadable' );
    };
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $d = eval { JSON::PP::decode_json( $raw // '' ) };
    return ref $d eq 'HASH' ? ( $d, 'ok' ) : ( undef, 'undecodable' );
}

sub _write_json {
    my ( $path, $data ) = @_;
    return write_private_atomic( $path, JSON::PP->new->canonical->encode($data), 0660 );
}

sub discovery_path { my ( $lz, $name ) = @_; return "$lz/$ID/discovery/$name.json" }

# ---- is a provider usable ----

# The remedy for each kind of fault, the words the log, the refusal and `lazysite
# check` give.
sub remedy {
    my ( $kind, $name, $docroot ) = @_;
    my $d = defined $docroot && length $docroot ? $docroot : 'DOCROOT';
    return {
        conf => "correct lazysite/oidc.conf (see /docs/auth), then run the OIDC extension's Refresh",
        unreadable => 'give lazysite/oidc.conf back to the site\'s user: lazysite-fix-perms, or chmod/chown it',
        secret => "set the client secret: extensions/oidc.pl --secret $name --docroot $d (it reads the secret from standard input)",
        secret_read => "lazysite/oidc/keys/$name.key cannot be read: lazysite-fix-perms, or give it back to the site's user",
        ca_file => "make $name.ca_file name a PEM file the site's user (and the web server's) can read, or remove the line to use the system store",
        discovery => "run the OIDC extension's Refresh (Extensions page, or extensions/oidc.pl --action refresh --docroot $d) once the issuer answers",
    }->{$kind} // '';
}

# ( $provider, '' ) for a provider that may sign people in now, or ( undef, why,
# kind ). Usable is: its config sound, its secret present and readable, its
# discovery fetched and cached.
sub usable {
    my ( $docroot, $lz, $name ) = @_;
    my ( $all, $why ) = providers($docroot);
    return ( undef, $why, 'unreadable' ) unless $all;
    my $p = $all->{ $name // '' } or return ( undef, "no OIDC provider is named '" . ( $name // '' ) . "'", 'conf' );
    return ( undef, join( '; ', @{ $p->{problems} } ), 'conf' ) if @{ $p->{problems} };
    my ( $secret, $st ) = Lazysite::Secrets::get( $lz, $ID, $name );
    return ( undef, "the client secret of '$name' is not set", 'secret' ) if $st eq 'absent';
    return ( undef, "the client secret of '$name' cannot be read", 'secret_read' ) unless $st eq 'ok';
    # Ruling 213: a CA bundle that is named and cannot be read refuses the provider,
    # never falls back to the system store.
    if ( length $p->{ca_file} ) {
        return ( undef, "$name.ca_file '$p->{ca_file}' is not a file", 'ca_file' ) unless -f $p->{ca_file};
        return ( undef, "$name.ca_file '$p->{ca_file}' cannot be read by this process", 'ca_file' ) unless -r _;
    }
    my ( $disc, $dst ) = _read_json( discovery_path( $lz, $name ) );
    return ( undef, "the discovery of '$name' has not been fetched", 'discovery' ) if $dst eq 'absent';
    return ( undef, "the discovery of '$name' cannot be read ($dst)", 'discovery' ) unless $dst eq 'ok';
    return ( undef, "the discovery of '$name' failed: " . ( $disc->{error} // 'no reason given' ), 'discovery' )
        unless $disc->{ok};
    return ( undef, "the discovery of '$name' was fetched for another issuer; refresh it", 'discovery' )
        unless ( $disc->{issuer} // '' ) eq $p->{issuer};
    return ( { %$p, secret => $secret, discovery => $disc }, '' );
}

# A refused provider is logged once per request with its fault and remedy.
sub log_refused {
    my ( $name, $why, $kind, $docroot ) = @_;
    log_event( 'WARN', 'auth', 'an OIDC provider is refused', provider => "$ID-" . ( $name // '' ),
        why => $why, fix => remedy( $kind, $name, $docroot ) );
    return;
}

# ---- the outside calls ----

sub _ua {
    my ($p) = @_;
    require LWP::UserAgent;
    # As a connector's agent (SM790): no redirect is followed, the answer is
    # capped, and TLS is verified (LWP's default, kept). Ruling 213: a provider
    # behind a private authority names its CA bundle (`<name>.ca_file`), used for
    # that provider's calls alone; verification stays on.
    my $ca = ref $p eq 'HASH' && length( $p->{ca_file} // '' ) ? $p->{ca_file} : undef;
    return LWP::UserAgent->new( timeout => $TIMEOUT, agent => 'lazysite-oidc/1', max_redirect => 0,
        max_size => $ANSWER_CAP,
        ( defined $ca ? ( ssl_opts => { verify_hostname => 1, SSL_ca_file => $ca } ) : () ) );
}

# ( $json, '' ) or ( undef, why ). The answer must be JSON, whole and under the cap.
sub _json_answer {
    my ( $res, $what ) = @_;
    return ( undef, "$what answered " . $res->code . ' and asked for another address; a redirect is not followed' )
        if $res->is_redirect;
    return ( undef, "$what answered " . $res->status_line ) unless $res->is_success;
    return ( undef, "$what answered more than the cap" ) if $res->header('Client-Aborted');
    my $d = eval { JSON::PP::decode_json( $res->decoded_content( charset => 'none' ) // '' ) };
    return ( undef, "$what did not answer JSON" ) unless ref $d eq 'HASH';
    return ( $d,    '' );
}

sub _well_known {
    my ($issuer) = @_;
    ( my $base = $issuer ) =~ s{/+\z}{};
    return "$base/.well-known/openid-configuration";
}

# Fetch one provider's discovery: ( $record ). Always a record, ok 1 or 0.
sub discover {
    my ($p) = @_;
    my $at  = time;
    my $res = _ua($p)->get( _well_known( $p->{issuer} ), Accept => 'application/json' );
    my ( $d, $why ) = _json_answer( $res, 'the discovery document' );
    return { ok => 0, at => $at, error => $why } unless $d;
    return { ok => 0, at => $at, error => "it names the issuer '" . ( $d->{issuer} // '' ) . "', not the configured one" }
        unless ( $d->{issuer} // '' ) eq $p->{issuer};
    for my $k (qw(authorization_endpoint token_endpoint)) {
        return { ok => 0, at => $at, error => "its $k is missing or not https://" } unless url_ok( $d->{$k} );
    }
    return { ok => 0, at => $at, error => 'its userinfo_endpoint is not https://' }
        if defined $d->{userinfo_endpoint} && !url_ok( $d->{userinfo_endpoint} );
    my $pk = $d->{code_challenge_methods_supported};
    return { ok => 0, at => $at, error => 'it does not offer PKCE with S256' }
        if ref $pk eq 'ARRAY' && !grep { ( $_ // '' ) eq 'S256' } @$pk;
    my $am = $d->{token_endpoint_auth_methods_supported};
    my $auth
        = ( ref $am ne 'ARRAY' || grep { ( $_ // '' ) eq 'client_secret_basic' } @$am ) ? 'client_secret_basic'
        : ( grep { ( $_ // '' ) eq 'client_secret_post' } @$am ) ? 'client_secret_post'
        :                                                          undef;
    return { ok => 0, at => $at, error => 'it takes neither client_secret_basic nor client_secret_post' } unless $auth;
    return { ok => 1, at => $at, issuer => $d->{issuer}, authorization_endpoint => $d->{authorization_endpoint},
        token_endpoint => $d->{token_endpoint}, auth_method => $auth,
        ( defined $d->{userinfo_endpoint} ? ( userinfo_endpoint => $d->{userinfo_endpoint} ) : () ) };
}

# The on_save hook and the Refresh action: fetch each sound provider's discovery
# and cache the answer, a failure as a failure. { ok, providers => { name => ... } }.
sub refresh {
    my ($docroot) = @_;
    require Lazysite::Paths;
    my $lz = Lazysite::Paths::lazysite_dir($docroot) // return { ok => 0, error => 'no document root' };
    my ( $all, $why ) = providers($docroot);
    return { ok => 0, error => $why, fix => remedy('unreadable') } unless $all;
    my $dir = _dir( $lz, 'discovery' ) // return { ok => 0, error => 'cannot make lazysite/oidc/discovery' };
    my ( %out, $fail );
    for my $name ( sort keys %$all ) {
        my $p = $all->{$name};
        if ( @{ $p->{problems} } ) {
            $out{$name} = { ok => 0, error => join( '; ', @{ $p->{problems} } ), fix => remedy('conf') };
            $fail = 1;
            unlink discovery_path( $lz, $name ) if $name =~ $NAME;
            next;
        }
        my $rec
            = ( length $p->{ca_file} && !( -f $p->{ca_file} && -r _ ) )
            ? { ok => 0, at => time, error => "$name.ca_file '$p->{ca_file}' cannot be read" }
            : discover($p);
        my ( $wok, $werr ) = _write_json( discovery_path( $lz, $name ), $rec );
        $rec = { ok => 0, error => "the discovery could not be kept: $werr" } unless $wok;
        $out{$name} = $rec->{ok} ? { ok => 1 } : { ok => 0, error => $rec->{error}, fix => remedy( 'discovery', $name, $docroot ) };
        $fail = 1 unless $rec->{ok};
        log_event( 'WARN', 'auth', 'an OIDC discovery failed', provider => "$ID-$name", why => $rec->{error} )
            unless $rec->{ok};
    }
    return { ok => $fail ? 0 : 1, providers => \%out };
}

# ---- the sign-in: start ----

sub _b64url {
    my ($raw) = @_;
    ( my $d = encode_base64( $raw, '' ) ) =~ tr{+/}{-_};
    $d =~ s/=+\z//;
    return $d;
}

sub _b64url_decode {
    my ($s) = @_;
    return undef unless defined $s && $s =~ /\A[A-Za-z0-9_-]*\z/;
    ( my $b = $s ) =~ tr{-_}{+/};
    $b .= '=' x ( ( 4 - length($b) % 4 ) % 4 );
    return decode_base64($b);
}

sub _enc {
    my ($s) = @_;
    $s =~ s/([^A-Za-z0-9._~-])/sprintf( '%%%02X', ord $1 )/ge;
    return $s;
}

sub _query_string {
    my (@kv) = @_;
    my @out;
    while ( my ( $k, $v ) = splice @kv, 0, 2 ) { push @out, _enc($k) . '=' . _enc($v) }
    return join '&', @out;
}

sub state_cookie_name { return "lzs_${ID}_state" }

sub _pending_file {
    my ( $lz, $state ) = @_;
    return "$lz/$ID/pending/" . sha256_hex("pending|$state") . '.json';
}

# Clear the records of sign-ins that were never finished.
sub _sweep {
    my ($dir) = @_;
    opendir my $dh, $dir or return;
    for my $f ( grep { /\A[0-9a-f]{64}\.json\z/ } readdir $dh ) {
        my $m = ( stat "$dir/$f" )[9] // next;
        unlink "$dir/$f" if $m < time - $PENDING_TTL;
    }
    closedir $dh;
    return;
}

# start( docroot, lz, name, next, base, secure, ip ) -> { ok => 1, location, cookie }
# or { ok => 0, status, error }. `base` is this site's address (scheme and host),
# from which the redirect URI is made.
#
# Ruling 213: A START IS A SIGN-IN ATTEMPT, counted per address by the sign-in
# limiter (Lazysite::Auth::LoginRate: its switch, five in five minutes), before
# anything is written, so unsigned GETs cannot fill the pending store.
sub start {
    my (%a) = @_;
    require Lazysite::Auth::LoginRate;
    unless ( Lazysite::Auth::LoginRate::check_login_rate( "$ID-ip=" . ( $a{ip} // '' ),
            auth_dir => "$a{lz}/auth", docroot => $a{docroot} ) )
    {
        log_event( 'WARN', 'auth', 'an OIDC sign-in start is refused: too many from this address',
            ip => $a{ip} // '' );
        return { ok => 0, status => '429 Too Many Requests',
            error => 'Too many sign-in attempts. Wait a few minutes and try again.' };
    }
    my ( $p, $why, $kind ) = usable( $a{docroot}, $a{lz}, $a{name} );
    unless ($p) {
        log_refused( $a{name}, $why, $kind, $a{docroot} );
        return { ok => 0, status => '503 Service Unavailable',
            error => 'This sign-in is not available. The site\'s administrator can see why with lazysite check.' };
    }
    require Lazysite::Endpoint;
    my $state    = Lazysite::Endpoint::random_hex(32);
    my $nonce    = Lazysite::Endpoint::random_hex(16);
    my $verifier = Lazysite::Endpoint::random_hex(32);
    return { ok => 0, status => '503 Service Unavailable', error => 'no source of random numbers' }
        unless defined $state && defined $nonce && defined $verifier;
    my $dir = _dir( $a{lz}, 'pending' )
        // return { ok => 0, status => '500 Internal Server Error', error => 'the sign-in cannot be recorded' };
    _sweep($dir);
    my $redirect = "$a{base}$ENDPOINT";
    my ( $wok, $werr ) = _write_json( _pending_file( $a{lz}, $state ), {
            name => $p->{name}, nonce => $nonce, verifier => $verifier, redirect_uri => $redirect,
            next => $a{next} // '/', exp => time + $PENDING_TTL } );
    unless ($wok) {
        log_event( 'WARN', 'auth', 'an OIDC sign-in could not be recorded', provider => $p->{provider}, why => $werr );
        return { ok => 0, status => '500 Internal Server Error', error => 'the sign-in cannot be recorded' };
    }
    my $auth = $p->{discovery}{authorization_endpoint};
    my $q    = _query_string(
        response_type => 'code', client_id => $p->{client_id}, redirect_uri => $redirect, scope => $p->{scopes},
        state => $state, nonce => $nonce, code_challenge => _b64url( sha256($verifier) ),
        code_challenge_method => 'S256' );
    my $sec = $a{secure} ? '; Secure' : '';
    return { ok => 1, location => $auth . ( index( $auth, '?' ) >= 0 ? '&' : '?' ) . $q,
        cookie => 'Set-Cookie: ' . state_cookie_name() . "=$state; Path=$ENDPOINT; HttpOnly; SameSite=Lax; Max-Age=$PENDING_TTL$sec" };
}

sub clear_state_cookie {
    my (%o) = @_;
    my $sec = $o{secure} ? '; Secure' : '';
    return 'Set-Cookie: ' . state_cookie_name() . "=; Path=$ENDPOINT; HttpOnly; SameSite=Lax; Max-Age=0$sec";
}

# ---- the sign-in: the provider's answer ----

sub _refused {
    my ( $prov, $why, $public ) = @_;
    log_event( 'WARN', 'auth', 'an OIDC sign-in is refused', provider => $prov // $ID, why => $why );
    return { ok => 0, status => '403 Forbidden', error => $public // 'That sign-in was not accepted.' };
}

# The claims of an ID token, unverified by signature (ruling 185), or undef.
sub id_token_claims {
    my ($jwt) = @_;
    return undef unless defined $jwt && !ref $jwt;
    my @part = split /\./, $jwt, -1;
    return undef unless @part == 3;
    my $raw = _b64url_decode( $part[1] ) // return undef;
    my $c   = eval { JSON::PP::decode_json($raw) };
    return ref $c eq 'HASH' ? $c : undef;
}

# The checks of OpenID Connect Core 3.1.3.7 that ruling 185 keeps: '' or why.
sub check_claims {
    my ( $c, $p, $nonce, $now ) = @_;
    $now //= time;
    return 'the ID token names another issuer' unless ( $c->{iss} // '' ) eq $p->{issuer};
    my @aud = ref $c->{aud} eq 'ARRAY' ? @{ $c->{aud} } : ( $c->{aud} // () );
    return 'the ID token is not for this client (aud)' unless grep { !ref && $_ eq $p->{client_id} } @aud;
    return 'the ID token has several audiences and no azp naming this client'
        if @aud > 1 && !defined $c->{azp};
    return 'the ID token is for another party (azp)' if defined $c->{azp} && $c->{azp} ne $p->{client_id};
    return 'the ID token carries no nonce, or another one'
        unless defined $c->{nonce} && !ref $c->{nonce} && const_eq( $c->{nonce}, $nonce );
    return 'the ID token has no expiry' unless defined $c->{exp} && $c->{exp} =~ /\A\d+\z/;
    return 'the ID token has expired'   unless $c->{exp} + $SKEW > $now;
    return 'the ID token was issued in the future' if defined $c->{iat} && $c->{iat} =~ /\A\d+\z/ && $c->{iat} > $now + $SKEW;
    return 'the ID token names no subject' unless defined $c->{sub} && !ref $c->{sub} && length $c->{sub};
    return '';
}

# The site groups a person's provider groups map to, in the map's order.
sub map_groups {
    my ( $map, $held ) = @_;
    my @held = ref $held eq 'ARRAY' ? grep { defined && !ref } @$held : ( defined $held && !ref $held ? ($held) : () );
    my ( %seen, @out );
    for my $g (@held) { push @out, grep { !$seen{$_}++ } @{ $map->{$g} || [] } }
    return @out;
}

# callback( docroot, lz, query, cookie, ip, ua ) -> { ok => 1, cookie, next,
# provider, login, groups } or { ok => 0, status, error }. `cookie` is the
# request's state cookie value.
sub callback {
    my (%a)   = @_;
    my $q     = $a{query} || {};
    my $state = $q->{state} // '';
    return _refused( undef, 'no state, or a state this site did not make' )
        unless $state =~ /\A[0-9a-f]{64}\z/;
    return _refused( undef, 'the state is not the one this browser was sent with (no state cookie, or another)' )
        unless defined $a{cookie} && const_eq( $a{cookie}, $state );
    my $file = _pending_file( $a{lz}, $state );
    my ( $pend, $pst ) = _read_json($file);
    unlink $file if $pst ne 'absent';    # single use, whatever follows
    return _refused( undef, "the sign-in this state names is not recorded ($pst)" ) unless $pst eq 'ok';
    return _refused( undef, 'the sign-in took too long', 'That sign-in took too long. Please try again.' )
        unless ( $pend->{exp} // 0 ) >= time;
    my $name = $pend->{name} // '';
    my $prov = "$ID-$name";
    if ( defined $q->{error} ) {
        ( my $e = substr( $q->{error}, 0, 64 ) ) =~ s/[^\w.-]//g;
        return _refused( $prov, "the provider answered error=$e" );
    }
    my ( $p, $why, $kind ) = usable( $a{docroot}, $a{lz}, $name );
    unless ($p) {
        log_refused( $name, $why, $kind, $a{docroot} );
        return { ok => 0, status => '503 Service Unavailable',
            error => 'This sign-in is not available. The site\'s administrator can see why with lazysite check.' };
    }
    my $code = $q->{code} // '';
    return _refused( $prov, 'the provider sent no code' ) unless length $code && $code !~ /[\x00-\x1f\x7f]/;

    # The token endpoint, with client authentication (ruling 185).
    my $d = $p->{discovery};
    my %form = ( grant_type => 'authorization_code', code => $code, redirect_uri => $pend->{redirect_uri},
        code_verifier => $pend->{verifier} );
    my @hdr = ( Accept => 'application/json' );
    if ( ( $d->{auth_method} // '' ) eq 'client_secret_post' ) {
        @form{qw(client_id client_secret)} = ( $p->{client_id}, $p->{secret} );
    }
    else {
        push @hdr, Authorization => 'Basic ' . encode_base64( _enc( $p->{client_id} ) . ':' . _enc( $p->{secret} ), '' );
    }
    my $res = _ua($p)->post( $d->{token_endpoint}, \%form, @hdr );
    my ( $tok, $twhy ) = _json_answer( $res, 'the token endpoint' );
    return _refused( $prov, $twhy ) unless $tok;
    my $claims = id_token_claims( $tok->{id_token} ) // return _refused( $prov, 'the token answer carries no ID token' );
    my $cwhy = check_claims( $claims, $p, $pend->{nonce} );
    return _refused( $prov, $cwhy ) if length $cwhy;

    # Anything the token does not carry, from userinfo, whose sub must be the token's.
    my %c = %$claims;
    if ( ( !exists $c{ $p->{group_claim} } || !defined $c{email} ) && defined $d->{userinfo_endpoint}
        && defined $tok->{access_token} && !ref $tok->{access_token} )
    {
        my $ur = _ua($p)->get( $d->{userinfo_endpoint}, Authorization => "Bearer $tok->{access_token}",
            Accept => 'application/json' );
        my ( $u, $uwhy ) = _json_answer( $ur, 'the userinfo endpoint' );
        return _refused( $prov, $uwhy )                                       unless $u;
        return _refused( $prov, 'the userinfo answer names another subject' ) unless ( $u->{sub} // '' ) eq $c{sub};
        exists $c{$_} or $c{$_} = $u->{$_} for keys %$u;
    }

    my $login = $c{sub};
    require Lazysite::Auth::Session;
    return _refused( $prov, 'the subject is not one a session can carry' )
        unless Lazysite::Auth::Session::provider_login_ok($login);
    my @groups = map_groups( $p->{map}, $c{ $p->{group_claim} } );
    return _refused( $prov, 'the person holds no group the map names, so no account is made',
        'You are not given access to this site by that sign-in.' ) unless @groups;
    my $display = ( grep { defined && !ref && length } @c{qw(email preferred_username name)} )[0] // $login;

    no warnings 'once';
    local $Lazysite::Auth::Session::LAZYSITE_DIR = $a{lz};
    my ($cookie) = Lazysite::Auth::Session::mint_provider_session( provider => $prov, login => $login,
        name => $display, groups => \@groups, ip => $a{ip}, ua => $a{ua} );
    return { ok => 0, status => '503 Service Unavailable', error => 'The site could not start a session.' }
        unless $cookie;
    log_event( 'INFO', 'auth', 'an OIDC sign-in', provider => $prov, user => "$prov:$login",
        groups => join( ',', @groups ) );
    return { ok => 1, cookie => $cookie, next => $pend->{next} // '/', provider => $prov, login => $login,
        groups => \@groups };
}

# ---- what core asks (H-1) ----

sub _ctx_name {
    my ($ctx) = @_;
    return undef unless ref $ctx eq 'HASH';
    return $ctx->{instance} if defined $ctx->{instance};
    return undef;
}

# Is this provider usable now; without one named, is any.
sub provider_on {
    my ($ctx) = @_;
    return 0 unless ref $ctx eq 'HASH';
    my $name = _ctx_name($ctx);
    if ( defined $name ) {
        my ( $p, $why, $kind ) = usable( $ctx->{docroot}, $ctx->{lazysite_dir}, $name );
        log_refused( $name, $why, $kind, $ctx->{docroot} ) unless $p;
        return $p ? 1 : 0;
    }
    my ($all) = providers( $ctx->{docroot} );
    return 0 unless $all;
    for my $n ( sort keys %$all ) {
        return 1 if ( usable( $ctx->{docroot}, $ctx->{lazysite_dir}, $n ) )[0];
    }
    return 0;
}

# The provider was asked at the sign-in; the session lasts as a local one does
# (session_lifetime), so a record is fresh for as long as core keeps it.
sub provider_still_valid { return 'ok' }

# The record's groups, less any the provider's current map no longer grants.
sub provider_groups {
    my ( $ctx, $rec ) = @_;
    my $name  = _ctx_name($ctx) // return [];
    my ($all) = providers( $ctx->{docroot} );
    my $p     = $all ? $all->{$name} : undef;
    return [] unless $p && $p->{map};
    my %granted = map { $_ => 1 } map { @$_ } values %{ $p->{map} };
    return [ grep { $granted{$_} } @{ ref $rec eq 'HASH' && ref $rec->{groups} eq 'ARRAY' ? $rec->{groups} : [] } ];
}

# /login: one option per usable provider.
sub provider_login_option {
    my ($ctx) = @_;
    my ($all) = providers( ref $ctx eq 'HASH' ? $ctx->{docroot} : undef );
    return [] unless $all;
    my @o;
    for my $n ( sort keys %$all ) {
        next unless ( usable( $ctx->{docroot}, $ctx->{lazysite_dir}, $n ) )[0];
        push @o, { id => "$ID-$n", label => $all->{$n}{label}, path => "$ENDPOINT?provider=$n" };
    }
    return \@o;
}

# ---- lazysite check (H-6) ----

sub check {
    my ( $docroot, $lz ) = @_;
    my @out;
    my ( $all, $why ) = providers($docroot);
    return [ { level => 'FAIL', text => "OIDC: $why - every OIDC sign-in is refused", fix => remedy('unreadable') } ]
        unless $all;
    return [ { level => 'WARN', text => 'OIDC: enabled, and lazysite/oidc.conf names no provider',
            fix => 'name them in lazysite/oidc.conf (providers: ...), see /docs/auth' } ]
        unless %$all;
    for my $n ( sort keys %$all ) {
        my ( $p, $pwhy, $kind ) = usable( $docroot, $lz, $n );
        push @out, $p
            ? { level => 'OK', text => "OIDC provider $n: ready ($p->{issuer})" }
            : { level => 'FAIL', text => "OIDC provider $n: refused - $pwhy", fix => remedy( $kind, $n, $docroot ) };
    }
    return \@out;
}

# ---- the secret, from the command line ----

sub set_secret {
    my ( $docroot, $name, $value ) = @_;
    return ( 0, 'name the provider: --secret <name>' ) unless defined $name && $name =~ $NAME;
    require Lazysite::Paths;
    my $lz = Lazysite::Paths::lazysite_dir($docroot) // return ( 0, 'no document root' );
    $value //= '';
    $value =~ s/[\r\n]+\z//;
    return Lazysite::Secrets::put( $lz, $ID, $name, $value );
}

1;
