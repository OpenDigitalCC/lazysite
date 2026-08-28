package ManagerSession;
# SM669: drive the manager API as a signed-in person, not as a token client.
#
# WHY THIS EXISTS. Cookie-side capability gates (%COOKIE_CAP) were asserted only
# as source text, because no test could reach them. SM660 shipped that way: its
# integration test was written, passed, and was deleted when sabotage showed the
# fixture never reached the gate at all. A table is a claim about behaviour, and
# the two can diverge - SM662 is the filing about how easily.
#
# WHAT IT TOOK, recorded because each of these cost a debugging session:
#
#   * THE MANAGER API DOES NOT READ A COOKIE. This is the thing that made the
#     gates untestable, and it is not written down anywhere a test author would
#     look. lazysite-auth.pl is the wrapper: it verifies the session cookie and
#     sets X-Remote-User, flagging LAZYSITE_AUTH_TRUSTED=1. The manager API
#     reads THAT header. Every previous attempt handed it a correctly signed
#     cookie - which verifies perfectly against the module, in isolation - and
#     got "Authentication required", because the CGI never looks at one.
#   * A cookie alone is not enough for a POST. Cookie POSTs need a CSRF token
#     (X-CSRF-Token, or csrf_token in the body). Without it the request fails
#     BEFORE the capability gate, and the failure does not mention CSRF - so a
#     test asserting "refused" passes for the wrong reason and keeps passing
#     with the gate deleted.
#   * The capability set must be written through the users TOOL, not by editing
#     groups-settings.json. The tool seeds on ordinary use and rewrites the
#     store, so a hand-written group can vanish mid-request.
#   * The auth secret must exist before the cookie is signed. An absent one
#     yields an empty signature, every call comes back anonymous, and a test
#     that then asserts a refusal is measuring nothing.
use strict;
use warnings;
use Exporter 'import';
our @EXPORT_OK = qw(new_site);

use File::Temp qw(tempdir);
use File::Path qw(make_path);
use IPC::Open3;
use Symbol qw(gensym);
use JSON::PP;
use Digest::SHA qw(hmac_sha256_hex);

sub new_site {
    my (%o) = @_;
    my $root = $o{root} or die 'new_site needs root => repo_root()';
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/auth");

    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} ( $o{conf} // "control_api_enabled: true\n" );
    close $cf;

    # Written BEFORE anything is signed. See the note above.
    open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
    print {$sf} ( 'c' x 64 );
    close $sf;
    chmod 0600, "$d/lazysite/auth/.secret";

    my $self = bless {
        docroot => $d,
        root    => $root,
        users   => "$root/tools/lazysite-users.pl",
        api     => "$root/lazysite-manager-api.pl",
    }, __PACKAGE__;
    return $self;
}

sub docroot { $_[0]{docroot} }

# Every store write goes through the tool that owns the store.
sub users {
    my ( $self, @args ) = @_;
    my $cmd = join ' ', map { quotemeta } ( $^X, $self->{users},
        '--docroot', $self->{docroot}, @args );
    return qx($cmd 2>&1);
}

sub add_user {
    my ( $self, $user, $pw ) = @_;
    $self->users( 'add', $user, ( $pw // 'pw123456789' ) );
    return $self;
}

# Put the user in a group and set EXACTLY the capabilities named - every other
# capability in @all is turned off, so a test states the whole grant rather
# than inheriting whatever a previous call left behind.
sub grant {
    my ( $self, $user, $group, $on, $all ) = @_;
    $self->users( 'group-add', $user, $group );
    my %want = map { $_ => 1 } @{ $on || [] };
    for my $c ( @{ $all || [] } ) {
        $self->users( 'group-set', $group, $c, $want{$c} ? 'on' : 'off' );
    }
    return $self;
}

# THE MODULE'S OWN READER, never a hand-rolled one. Reading the file here means
# reproducing exactly how it is chomped and trimmed, and getting that subtly
# wrong yields a signature mismatch that presents as "Authentication required" -
# indistinguishable from a broken gate. t/integration/60 carries the same
# warning; this harness was written with a hand-rolled reader anyway and lost a
# debugging session to it.
sub _secret {
    my ($self) = @_;
    require Lazysite::Auth::Session;
    no warnings 'once';
    local $Lazysite::Auth::Session::LAZYSITE_DIR = $self->{docroot} . '/lazysite';
    return Lazysite::Auth::Session::_auth_secret_read() // '';
}

# The legacy three-field payload (user:ts:groups), matching what the auth layer
# accepts without a session-registry entry - a made-up session id reads as
# REVOKED, and minting a real one would be testing the login flow instead.
sub cookie_for {
    my ( $self, $user ) = @_;
    my $sec = $self->_secret();
    return '' unless length $sec;
    my $payload = "$user:" . time . ':';
    return 'lazysite_auth=' . $payload . ':' . hmac_sha256_hex( $payload, $sec );
}

# Same derivation as Session::generate_csrf_token, from the same secret.
sub csrf_for {
    my ( $self, $user ) = @_;
    my $sec = $self->_secret();
    return '' unless length $sec;
    return hmac_sha256_hex( 'csrf:' . $user . ':' . int( time() / 3600 ), $sec );
}

# A manager request as that user. GET by default; pass body => {...} for a POST,
# and the CSRF token is attached automatically - forgetting it is the mistake
# this harness exists to stop anyone repeating.
sub call {
    my ( $self, $user, $action, %o ) = @_;
    my $body = $o{body};
    my $json = defined $body ? encode_json($body) : undef;

    local %ENV = %ENV;
    delete @ENV{qw(HTTP_AUTHORIZATION LAZYSITE_AUTH_TOKEN)};

    # STANDING IN FOR THE AUTH WRAPPER, which is what lazysite-auth.pl does in
    # production: verify the cookie, then vouch for the user with X-Remote-User
    # and LAZYSITE_AUTH_TRUSTED=1. The manager API refuses an asserted
    # X-Remote-User that the wrapper did not vouch for, so both are required.
    #
    # The cookie is still sent, because some paths read it and because a test
    # that omitted it would diverge from a real request in a way nobody would
    # notice until it mattered.
    $ENV{HTTP_X_REMOTE_USER}     = $user;
    $ENV{LAZYSITE_AUTH_TRUSTED}  = '1';
    $ENV{DOCUMENT_ROOT}       = $self->{docroot};
    $ENV{LAZYSITE_USERS_TOOL} = $self->{users};
    $ENV{QUERY_STRING}        = $o{query} // "action=$action";
    $ENV{REQUEST_METHOD}      = defined $json ? 'POST' : 'GET';
    $ENV{CONTENT_LENGTH}      = defined $json ? length($json) : 0;
    $ENV{HTTP_COOKIE}         = $self->cookie_for($user);
    $ENV{HTTP_X_CSRF_TOKEN}   = $self->csrf_for($user);

    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $self->{api} );
    print {$w} ( defined $json ? $json : '' );
    close $w;
    my $out = do { local $/; <$r> };
    my $err = do { local $/; <$e> };
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    my $res = eval { decode_json( $jb // '' ) };
    return ref $res eq 'HASH' ? $res : { _raw => $out, _err => $err };
}

# A CAPABILITY refusal specifically - not a 404, not CSRF, not anonymity. The
# distinction is the whole point: every one of those also produces ok:false.
sub refused_for_capability {
    my ( $class, $res ) = @_;
    return 0 unless ref $res eq 'HASH';
    return 0 unless ( $res->{kind} // '' ) eq 'forbidden';
    return ( $res->{error} // '' ) =~ /permission|capability/i ? 1 : 0;
}

1;
