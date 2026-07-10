#!/usr/bin/perl
# SM141 phase 1: session registry + revocation in the auth wrapper.
#   - login mints a 4-field cookie (user:ts:sid:groups, sid 16 hex) and appends
#     a sanitised {sid,user,t,ip,ua} line to lazysite/auth/sessions.jsonl
#   - legacy 3-field cookies (user:ts:groups) stay valid until natural expiry
#   - a revoked sid rejects THAT cookie; other sessions keep working
#   - a per-user not_before rejects ALL of that user's cookies, legacy included
#   - a corrupt revoked.json fails OPEN with a loud WARN (never a lockout)
#   - the registry self-prunes lines older than COOKIE_MAX on write
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough);

my $root = repo_root();
my $auth = "$root/lazysite-auth.pl";
my $utl  = "$root/tools/lazysite-users.pl";

sub users_api {
    my ( $docroot, $payload ) = @_;
    my ( $cout, $cin );
    my $pid = open2( $cout, $cin, $^X, $utl, '--api', '--docroot', $docroot );
    print $cin encode_json($payload);
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;
    return decode_json($out);
}

# POST /login through the auth wrapper. Returns stdout + stderr.
sub login {
    my (%o) = @_;
    my $body = "username=$o{username}&password=" . ( $o{password} // '' ) . "&next=/";
    local %ENV = (
        env_passthrough(),   # keep coverage instrumentation for the CGI child
        DOCUMENT_ROOT  => $o{docroot},
        REQUEST_METHOD => 'POST',
        QUERY_STRING   => 'action=login',
        CONTENT_LENGTH => length($body),
        CONTENT_TYPE   => 'application/x-www-form-urlencoded',
        REMOTE_ADDR    => $o{addr} // '127.0.0.1',
        HTTPS          => '',
        ( defined $o{ua} ? ( HTTP_USER_AGENT => $o{ua} ) : () ),
    );
    my ( $wtr, $rdr );
    my $err = gensym;
    my $pid = open3( $wtr, $rdr, $err, $^X, $auth );
    print $wtr $body;
    close $wtr;
    my $out  = do { local $/; <$rdr> };
    my $eout = do { local $/; <$err> };
    waitpid $pid, 0;
    return { out => $out // '', err => $eout // '' };
}

# A stub "processor" that dumps the trusted env the wrapper set, so a GET
# through the wrapper reveals whether the cookie was accepted (USER=) and
# which session id was passed down (SID=).
my $stubdir = tempdir( CLEANUP => 1 );
my $stub    = "$stubdir/stub-processor.pl";
open my $stf, '>', $stub or die $!;
print $stf <<'STUB';
#!/usr/bin/perl
print "Status: 200 OK\r\nContent-Type: text/plain\r\n\r\n";
print "USER=", ( $ENV{HTTP_X_REMOTE_USER} // '' ), "\n";
print "SID=",  ( $ENV{LAZYSITE_AUTH_SID}  // '' ), "\n";
STUB
close $stf;

# GET / through the wrapper with a cookie; returns stdout + stderr.
sub auth_get {
    my ( $docroot, $cookie ) = @_;
    local %ENV = (
        env_passthrough(),
        DOCUMENT_ROOT      => $docroot,
        REDIRECT_URL       => '/',
        REQUEST_METHOD     => 'GET',
        QUERY_STRING       => '',
        REMOTE_ADDR        => '127.0.0.1',
        LAZYSITE_PROCESSOR => $stub,
        ( $cookie ? ( HTTP_COOKIE => "lazysite_auth=$cookie" ) : () ),
    );
    my ( $wtr, $rdr );
    my $err = gensym;
    my $pid = open3( $wtr, $rdr, $err, $^X, $auth );
    close $wtr;
    my $out  = do { local $/; <$rdr> };
    my $eout = do { local $/; <$err> };
    waitpid $pid, 0;
    return { out => $out // '', err => $eout // '' };
}

sub build_docroot {
    my $d = tempdir( CLEANUP => 1 );
    mkdir "$d/lazysite";
    mkdir "$d/lazysite/auth";
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: T\n";
    close $cf;
    return $d;
}

sub read_secret {
    my ($d) = @_;
    open my $fh, '<', "$d/lazysite/auth/.secret" or die "no secret: $!";
    chomp( my $s = <$fh> );
    close $fh;
    return $s;
}

# Hand-mint a signed cookie from a payload (the payloads used here contain
# only cookie-safe chars, so no uri-encoding step is needed).
sub mint_cookie {
    my ( $d, $payload ) = @_;
    return $payload . ':' . hmac_sha256_hex( $payload, read_secret($d) );
}

sub cookie_from {
    my ($out) = @_;
    return $out =~ /Set-Cookie:\s*lazysite_auth=([^;]+);/ ? $1 : '';
}

sub payload_of {
    my ($cookie) = @_;
    my ($enc) = $cookie =~ /^(.+):[a-f0-9]{64}$/;
    $enc //= '';
    $enc =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    return $enc;
}

sub write_revoked {
    my ( $d, $data ) = @_;
    open my $fh, '>', "$d/lazysite/auth/revoked.json" or die $!;
    print $fh ref $data ? encode_json($data) : $data;
    close $fh;
}

# --- login mints a 4-field cookie + a sanitised registry line ----------------
my $d1 = build_docroot();
my ( $sid1, $cookie1 );
{
    users_api( $d1, { action => 'add', username => 'alice', password => 'pw' } );
    my $nasty_ua = "Test\x01Agent\x7f/1.0 " . ( 'X' x 200 );
    my $r = login( docroot => $d1, username => 'alice', password => 'pw', ua => $nasty_ua );
    like( $r->{out}, qr/302 Found/, 'login succeeds' );
    $cookie1 = cookie_from( $r->{out} );
    ok( length $cookie1, 'cookie captured' );

    my @f = split /:/, payload_of($cookie1), 4;
    is( scalar @f, 4, 'payload has 4 fields (user:ts:sid:groups)' );
    is( $f[0], 'alice', 'payload user' );
    like( $f[1], qr/^\d+$/, 'payload ts is numeric' );
    like( $f[2], qr/^[0-9a-f]{16}$/, 'payload sid is exactly 16 hex chars' );
    $sid1 = $f[2];

    open my $rf, '<', "$d1/lazysite/auth/sessions.jsonl" or die "no registry: $!";
    my @lines = <$rf>;
    close $rf;
    is( scalar @lines, 1, 'registry has one line after one login' );
    my $rec = decode_json( $lines[0] );
    is( $rec->{sid},  $sid1,       'registry sid matches the cookie sid' );
    is( $rec->{user}, 'alice',     'registry user' );
    is( $rec->{t},    $f[1] + 0,   'registry t is the cookie ts' );
    is( $rec->{ip},   '127.0.0.1', 'registry ip' );
    unlike( $rec->{ua}, qr/[\x00-\x1f\x7f]/, 'registry ua has control chars stripped' );
    cmp_ok( length( $rec->{ua} ), '<=', 120, 'registry ua truncated to 120' );
    like( $rec->{ua}, qr/^TestAgent\/1\.0 X/, 'registry ua content survives sanitisation' );
}

# --- a legacy 3-field cookie is still accepted --------------------------------
{
    my $legacy = mint_cookie( $d1, 'alice:' . ( time() - 100 ) . ':admins' );
    my $r = auth_get( $d1, $legacy );
    like( $r->{out}, qr/^USER=alice$/m, 'legacy 3-field cookie authenticates' );
    like( $r->{out}, qr/^SID=$/m,       'legacy cookie carries no sid downstream' );
}

# --- sid revocation: that cookie dies, another session lives ------------------
{
    my $r2 = login( docroot => $d1, username => 'alice', password => 'pw' );
    my $cookie2 = cookie_from( $r2->{out} );
    ok( length $cookie2, 'second session cookie captured' );

    write_revoked( $d1, { sids => { $sid1 => time() }, not_before => {} } );

    my $a = auth_get( $d1, $cookie1 );
    like( $a->{out}, qr/^USER=$/m, 'revoked sid: cookie rejected' );
    like( $a->{err}, qr/session revoked/, 'revoked sid: WARN logged' );

    my $b = auth_get( $d1, $cookie2 );
    like( $b->{out}, qr/^USER=alice$/m, 'other session still works' );
    like( $b->{out}, qr/^SID=[0-9a-f]{16}$/m, 'sid passed to the child for the live session' );
}

# --- per-user not_before kills ALL that user's cookies (legacy too) -----------
{
    my $d = build_docroot();
    users_api( $d, { action => 'add', username => 'bob', password => 'pw' } );
    # Mint the secret via a real login, then hand-mint bob's cookies in the past.
    my $r = login( docroot => $d, username => 'bob', password => 'pw' );
    like( $r->{out}, qr/302 Found/, 'bob logs in (secret minted)' );

    my $ts      = time() - 50;
    my $current = mint_cookie( $d, "bob:$ts:0123456789abcdef:admins" );
    my $legacy  = mint_cookie( $d, "bob:$ts:admins" );
    my $other   = mint_cookie( $d, 'carol:' . time() . ':fedcba9876543210:' );

    write_revoked( $d, { sids => {}, not_before => { bob => time() - 10 } } );

    my $a = auth_get( $d, $current );
    like( $a->{out}, qr/^USER=$/m, 'not_before: 4-field cookie rejected' );
    like( $a->{err}, qr/session revoked/, 'not_before: WARN logged' );

    my $b = auth_get( $d, $legacy );
    like( $b->{out}, qr/^USER=$/m, 'not_before: legacy cookie rejected too' );

    my $c = auth_get( $d, $other );
    like( $c->{out}, qr/^USER=carol$/m, 'another user is unaffected' );
}

# --- corrupt revoked.json: fail open with a loud WARN --------------------------
{
    my $d = build_docroot();
    users_api( $d, { action => 'add', username => 'carol', password => 'pw' } );
    write_revoked( $d, "this is { not json" );

    my $r = login( docroot => $d, username => 'carol', password => 'pw' );
    like( $r->{out}, qr/302 Found/, 'corrupt revoked.json: login still works' );
    my $cookie = cookie_from( $r->{out} );

    my $a = auth_get( $d, $cookie );
    like( $a->{out}, qr/^USER=carol$/m, 'corrupt revoked.json: valid cookie still accepted' );
    like( $a->{err}, qr/revoked\.json unreadable or corrupt/,
        'corrupt revoked.json: WARN on stderr' );
}

# --- the registry self-prunes stale lines on write -----------------------------
{
    my $d = build_docroot();
    users_api( $d, { action => 'add', username => 'dave', password => 'pw' } );
    open my $rf, '>', "$d/lazysite/auth/sessions.jsonl" or die $!;
    print $rf encode_json( { sid => 'ffffffffffffffff', user => 'ancient',
        t => time() - 2 * 86400, ip => '9.9.9.9', ua => 'old' } ) . "\n";
    close $rf;

    my $r = login( docroot => $d, username => 'dave', password => 'pw' );
    like( $r->{out}, qr/302 Found/, 'login over a stale registry succeeds' );

    open my $in, '<', "$d/lazysite/auth/sessions.jsonl" or die $!;
    my $all = do { local $/; <$in> };
    close $in;
    unlike( $all, qr/ancient/, 'stale line pruned' );
    like( $all, qr/"user":"dave"/, 'fresh login recorded' );
    is( scalar( split /\n/, $all ), 1, 'exactly one line remains' );
}

done_testing();
