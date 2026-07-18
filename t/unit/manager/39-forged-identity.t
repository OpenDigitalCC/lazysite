#!/usr/bin/perl
# ADVERSARIAL (advisory 2026-07): a client must not be able to ASSERT an identity
# to the manager-API by sending X-Remote-* headers itself. Those headers are
# trustworthy only when the auth wrapper sets them from a verified cookie and
# flags LAZYSITE_AUTH_TRUSTED=1. This test forges the headers WITHOUT the flag -
# exactly what an attacker's tool does on an edge that fails to strip them - and
# asserts the manager-API treats the request as UNAUTHENTICATED (no operator
# access, no account takeover, no privilege escalation), while the genuinely
# wrapper-vouched request (flag set) still works.
use strict;
use warnings;
use Test::More;
use JSON::PP    qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use IPC::Open2  qw(open2);
use IPC::Open3  qw(open3);
use Symbol      qw(gensym);
use File::Path  qw(make_path);
use File::Temp  qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps);

my $root   = repo_root();
my $utool  = "$root/tools/lazysite-users.pl";
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sekret' x 6;

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}

# Run the manager-API. $trusted controls whether the wrapper's LAZYSITE_AUTH_TRUSTED
# flag is set: 0 = a FORGED request (headers only, as an attacker sends), 1 = a
# genuinely wrapper-authenticated request.
sub mapi {
    my ( $d, $trusted, %o ) = @_;
    my $body = delete $o{body};
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{REQUEST_METHOD} = $o{REQUEST_METHOD} || 'GET';
    $ENV{CONTENT_LENGTH} = defined $body ? length($body) : 0;
    delete $ENV{HTTP_X_REMOTE_USER};
    delete $ENV{HTTP_X_REMOTE_GROUPS};
    delete $ENV{LAZYSITE_AUTH_TRUSTED};
    $ENV{$_} = $o{$_} for grep { defined $o{$_} } keys %o;
    $ENV{LAZYSITE_AUTH_TRUSTED} = 1 if $trusted;    # ONLY the wrapper sets this
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    print $w( defined $body ? $body : '' );
    close $w;
    my $out = do { local $/; <$r> };
    close $r;
    my $err = do { local $/; <$e> };    # log_event WARN lands on STDERR
    close $e;
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    my $res = eval { decode_json( $jb // '' ) } // { _raw => $out };
    $res->{_stderr} = $err // '' if ref $res eq 'HASH';
    return $res;
}
sub csrf { hmac_sha256_hex( "csrf:$_[0]:" . int( time() / 3600 ), $secret ) }

# --- a SECURED site: some group grants manager access ------------------------
my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "site_name: T\n";    # NB: no auth_proxy_trusted -> headers are not trusted
close $cf;
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
print $sf $secret;
close $sf;

uapi( $d, { action => 'add', username => 'op', password => 'x' } );
grant_caps( $d, 'op', 'manage_users' );    # role-op is now a manager group => secured
uapi( $d, { action => 'add', username => 'alice', password => 'alicepass' } );

my $HU = 'op';
my $HG = 'role-op';    # the admin/manager group

# --- FORGED: headers without the wrapper flag are treated as unauthenticated ---
{
    my $r = mapi( $d, 0, QUERY_STRING => 'action=csrf-token',
        HTTP_X_REMOTE_USER => $HU, HTTP_X_REMOTE_GROUPS => $HG );
    ok( !$r->{ok}, 'forged X-Remote-* does NOT get a CSRF token' ) or diag encode_json($r);
    like( $r->{error} // '', qr/Authentication required/i,
        'forged identity is refused as unauthenticated' );
}

# Account takeover / privilege escalation via forged headers must NOT work. We
# supply a CSRF token too (an attacker would): it must not rescue the forgery.
{
    my $tok = csrf($HU);
    my $pw = mapi( $d, 0, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=users',
        HTTP_X_REMOTE_USER => $HU, HTTP_X_REMOTE_GROUPS => $HG, HTTP_X_CSRF_TOKEN => $tok,
        body => encode_json( { action => 'passwd', username => 'alice', password => 'pwned' } ) );
    ok( !$pw->{ok}, 'forged headers cannot reset another account password (no takeover)' );

    my $ga = mapi( $d, 0, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=users',
        HTTP_X_REMOTE_USER => $HU, HTTP_X_REMOTE_GROUPS => $HG, HTTP_X_CSRF_TOKEN => $tok,
        body => encode_json( { action => 'group-add', username => 'alice', group => 'role-op' } ) );
    ok( !$ga->{ok}, 'forged headers cannot add a user to the admin group (no escalation)' );

    # The victim did not become an admin on disk.
    my $groups = do { open my $fh, '<', "$d/lazysite/auth/groups-settings.json"; local $/; <$fh> // '' };
    unlike( $groups // '', qr/alice/, 'alice was not added to any group by the forged request' );
}

# --- the WARN is emitted so the attempt is visible (not a silent bypass) ------
{
    my $r = mapi( $d, 0, QUERY_STRING => 'action=csrf-token',
        HTTP_X_REMOTE_USER => $HU, HTTP_X_REMOTE_GROUPS => $HG );
    like( $r->{_stderr} // '', qr/untrusted auth header ignored/,
        'a forged header is logged (WARN on STDERR - the bypass is not silent)' );
}

# --- the genuinely wrapper-vouched request (flag set) still works -------------
{
    my $r = mapi( $d, 1, QUERY_STRING => 'action=csrf-token',
        HTTP_X_REMOTE_USER => $HU, HTTP_X_REMOTE_GROUPS => $HG );
    ok( $r->{ok} && $r->{token}, 'a wrapper-authenticated request (LAZYSITE_AUTH_TRUSTED) still gets a token' )
        or diag encode_json($r);
}

done_testing;
