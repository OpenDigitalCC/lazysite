#!/usr/bin/perl
# SEC-2026-07 (M4 + M5): server-side session invalidation and per-request group
# re-resolution in the auth wrapper.
#   M4 - logout must revoke the session's sid (add it to revoked.json), so a
#        cookie captured before logout stops authenticating immediately, not
#        only after the 24h TTL. A legacy (sid-less) cookie can't be revoked
#        individually - it still ages out.
#   M5 - the trusted X-Remote-Groups must be re-resolved from the live groups
#        file each request, not taken from the (stale) cookie: a demotion takes
#        effect at once, a promotion too.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
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
    require JSON::PP;
    my ( $cout, $cin );
    my $pid = open2( $cout, $cin, $^X, $utl, '--api', '--docroot', $docroot );
    print $cin JSON::PP::encode_json($payload);
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;
    return JSON::PP::decode_json($out);
}

# A stub processor that dumps the trusted env the wrapper set.
my $stubdir = tempdir( CLEANUP => 1 );
my $stub    = "$stubdir/stub.pl";
open my $stf, '>', $stub or die $!;
print $stf <<'STUB';
#!/usr/bin/perl
print "Status: 200 OK\r\nContent-Type: text/plain\r\n\r\n";
print "USER=",   ( $ENV{HTTP_X_REMOTE_USER}   // '' ), "\n";
print "GROUPS=", ( $ENV{HTTP_X_REMOTE_GROUPS} // '' ), "\n";
STUB
close $stf;

sub _run {
    my (%o) = @_;
    local %ENV = (
        env_passthrough(),
        DOCUMENT_ROOT      => $o{docroot},
        REDIRECT_URL       => $o{uri}    // '/',
        REQUEST_METHOD     => $o{method} // 'GET',
        QUERY_STRING       => $o{qs}     // '',
        CONTENT_LENGTH     => defined $o{body} ? length $o{body} : 0,
        CONTENT_TYPE       => 'application/x-www-form-urlencoded',
        REMOTE_ADDR        => '127.0.0.1',
        HTTPS              => '',
        LAZYSITE_PROCESSOR => $stub,
        ( $o{cookie} ? ( HTTP_COOKIE => "lazysite_auth=$o{cookie}" ) : () ),
    );
    my ( $wtr, $rdr );
    my $err = gensym;
    my $pid = open3( $wtr, $rdr, $err, $^X, $auth );
    print $wtr( $o{body} // '' );
    close $wtr;
    my $out  = do { local $/; <$rdr> };
    my $eout = do { local $/; <$err> };
    waitpid $pid, 0;
    return { out => $out // '', err => $eout // '' };
}

sub login {
    my ( $d, $u, $p ) = @_;
    my $body = "username=$u&password=$p&next=/";
    my $r = _run( docroot => $d, method => 'POST', qs => 'action=login', body => $body );
    return $r->{out} =~ /Set-Cookie:\s*lazysite_auth=([^;]+);/ ? $1 : '';
}
sub get { _run( docroot => $_[0], cookie => $_[1] ) }
sub logout { _run( docroot => $_[0], qs => 'action=logout', cookie => $_[1] ) }

sub build_docroot {
    my $d = tempdir( CLEANUP => 1 );
    mkdir "$d/lazysite";
    mkdir "$d/lazysite/auth";
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: T\n";
    close $cf;
    return $d;
}

sub set_groups {
    my ( $d, $text ) = @_;
    open my $fh, '>', "$d/lazysite/auth/groups" or die $!;
    print $fh $text;
    close $fh;
}

# === M4: logout invalidates the session server-side =========================
{
    my $d = build_docroot();
    users_api( $d, { action => 'add', username => 'alice', password => 'pw' } );
    my $cookie = login( $d, 'alice', 'pw' );
    ok( length $cookie, 'alice logged in' );

    like( get( $d, $cookie )->{out}, qr/^USER=alice$/m,
        'the cookie authenticates before logout' );

    my $lo = logout( $d, $cookie );
    like( $lo->{out}, qr/302 Found/, 'logout returns a redirect' );
    ok( -f "$d/lazysite/auth/revoked.json", 'logout wrote revoked.json' );

    my $after = get( $d, $cookie );
    like( $after->{out}, qr/^USER=$/m,
        'M4: the SAME cookie no longer authenticates after logout' );
    like( $after->{err}, qr/session revoked/, 'M4: revocation is logged' );
}

# A legacy (sid-less) cookie: logout can't revoke a specific sid, but must not
# error - the cookie still ages out at its TTL.
{
    my $d = build_docroot();
    users_api( $d, { action => 'add', username => 'bob', password => 'pw' } );
    login( $d, 'bob', 'pw' );    # mint the secret
    require Digest::SHA;
    open my $sf, '<', "$d/lazysite/auth/.secret" or die $!;
    chomp( my $secret = <$sf> );
    close $sf;
    my $payload = 'bob:' . ( time() - 10 ) . ':admins';    # 3-field legacy shape
    my $legacy  = $payload . ':' . Digest::SHA::hmac_sha256_hex( $payload, $secret );

    my $lo = logout( $d, $legacy );
    like( $lo->{out}, qr/302 Found/, 'legacy-cookie logout still returns a redirect' );
    unlike( $lo->{err}, qr/revoke failed/, 'legacy-cookie logout logs no error' );
}

# === M5: groups are re-resolved from the live file each request =============
{
    my $d = build_docroot();
    users_api( $d, { action => 'add', username => 'carol', password => 'pw' } );
    set_groups( $d, "admins: carol\n" );

    my $cookie = login( $d, 'carol', 'pw' );
    like( get( $d, $cookie )->{out}, qr/^GROUPS=admins$/m,
        'carol carries the admins group while a member' );

    # Demote carol out of admins - do NOT re-issue the cookie.
    set_groups( $d, "admins:\n" );
    like( get( $d, $cookie )->{out}, qr/^GROUPS=$/m,
        'M5: demotion takes effect immediately on the existing cookie' );

    # Promote into a different group - also immediate.
    set_groups( $d, "editors: carol\n" );
    like( get( $d, $cookie )->{out}, qr/^GROUPS=editors$/m,
        'M5: promotion also re-resolved immediately' );
}

done_testing();
