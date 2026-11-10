#!/usr/bin/perl
# SM1430 (0.16.10 edge, O-1): A PUBLIC PAGE CLEARS THE SIGNED-IN MARKER A SESSION THAT NO
# LONGER VERIFIES LEFT BEHIND, ON BOTH PATHS.
#
# After "Require sign-in again" on a local session (ruling 219: it signs that session
# out), the browser's public pages still drew "Sign out": the display-only lzs_session
# marker (SM099) stayed while the manager API answered 401, until a visit to /manager/
# took the /login bounce that clears it. A page response to a request carrying the marker
# and no signed-in identity now clears the marker through the helper's clearing twin,
# and is not stored by any cache; the HttpOnly session cookie is left alone.
#
#   the CGI     the auth wrapper verifies, and execs the processor;
#   the pool    the front door decides the identity in the worker (SM1181 S3).
#
# Controls: a valid session with the marker keeps it; a visitor with no cookies, and a
# revoked session cookie without the marker, get no Set-Cookie and the page's own
# Cache-Control - a cached public page stays cacheable.
#
# With the change reverted: the revoked, removed-account and marker-only requests carry
# no clearing header, on both paths.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use POSIX       qw(dup2);
use Socket      qw(AF_UNIX SOCK_STREAM sockaddr_un);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir);

my $root = repo_root();
my $d    = site_tempdir();
( my $base = $d ) =~ s{/[^/]+\z}{};
my $LZ = "$d/lazysite";
make_path("$LZ/auth");

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}
sub slurp { open my $fh, '<', $_[0] or return ''; local $/; return scalar <$fh> // '' }

my $SECRET = 'f' x 64;
spit( "$LZ/lazysite.conf", "site_name: T\n" );
spit( "$LZ/auth/.secret",  "$SECRET\n" );
chmod 0600, "$LZ/auth/.secret";
spit( "$LZ/auth/users", "alice:x\n" );
spit( "$LZ/auth/user-settings.json", "{}\n" );
spit( "$d/index.md", "---\ntitle: Home\nttl: 300\n---\nHOME BODY\n" );

my $LIVE = 'a1a1a1a1a1a1a1a1';
my $DEAD = 'd0d0d0d0d0d0d0d0';
# The revoked session: its sid is in revoked.json, as session-revoke leaves it.
spit( "$LZ/auth/revoked.json", qq({"sids":{"$DEAD":1}}\n) );

# A current four-field cookie (user:ts:sid:groups), signed with the site secret.
sub session_for {
    my ( $user, $sid ) = @_;
    my $payload = join ':', $user, time(), $sid, '';
    return "lazysite_auth=$payload:" . hmac_sha256_hex( $payload, $SECRET );
}
my $MARK = 'lzs_session=1';
my %CASE = (
    valid        => session_for( 'alice', $LIVE ) . "; $MARK",
    revoked      => session_for( 'alice', $DEAD ) . "; $MARK",
    removed      => session_for( 'gone',  $LIVE ) . "; $MARK",
    marker_only  => $MARK,
    none         => undef,
    revoked_bare => session_for( 'alice', $DEAD ),
);

my $CLEAR = qr/^Set-Cookie: lzs_session=; SameSite=Lax; Path=\/; Max-Age=0\r?$/m;

sub head_of { my ($out) = @_; my ($h) = split /\r?\n\r?\n/, $out // '', 2; return $h // '' }

sub check_all {
    my ( $get, $where ) = @_;
    for my $k (qw(revoked removed marker_only)) {
        my $out = $get->( $CASE{$k} );
        my $h   = head_of($out);
        like( $out, qr/HOME BODY/, "$where, $k: the public page is served" );
        like( $h, $CLEAR, "$where, $k: the response clears the marker" ) or diag($h);
        like( $h, qr/^Cache-Control: no-store, private\r?$/m, "$where, $k: and is never stored" );
        unlike( $h, qr/^Set-Cookie: lazysite_auth=/m, "$where, $k: the session cookie is left alone" );
    }
    {
        my $h = head_of( $get->( $CASE{valid} ) );
        unlike( $h, qr/^Set-Cookie:/m, "$where, valid: a live session keeps its marker" ) or diag($h);
    }
    for my $k (qw(none revoked_bare)) {
        for my $n ( 1, 2 ) {    # the second is the render cache's hit
            my $h = head_of( $get->( $CASE{$k} ) );
            unlike( $h, qr/^Set-Cookie:/m, "$where, $k ($n): no marker, no Set-Cookie" ) or diag($h);
            like( $h, qr/^Cache-Control: public, max-age=300\r?$/m, "$where, $k ($n): the page stays cacheable" )
                or diag($h);
        }
    }
    return;
}

# --- the CGI path: the auth wrapper ----------------------------------------------

sub via_wrapper {
    my ($cookie) = @_;
    my $err = "$base/wrapper-stderr.log";
    local %ENV = ( env_passthrough(), DOCUMENT_ROOT => $d, REQUEST_METHOD => 'GET',
        REDIRECT_URL => '/', REQUEST_URI => '/', QUERY_STRING => '', REMOTE_ADDR => '198.51.100.1',
        HTTP_HOST => 'site.test', LAZYSITE_PROCESSOR => "$root/lazysite-processor.pl",
        LAZYSITE_LOG_LEVEL => 'ERROR', ( defined $cookie ? ( HTTP_COOKIE => $cookie ) : () ) );
    my $out = qx(\Q$^X\E \Q$root/lazysite-auth.pl\E 2>\Q$err\E);
    return $out;
}

subtest 'the CGI path' => sub { check_all( \&via_wrapper, 'CGI' ) };

# --- the pool: the front door in the worker --------------------------------------

SKIP: {
    skip 'FCGI.pm not installed (the plain-CGI path is the fallback)', 1 unless eval { require FCGI; 1 };
    require MiniFcgi;
    my $cgibin = "$base/cgi-bin";
    make_path($cgibin);
    symlink "$root/lazysite-processor.pl", "$cgibin/lazysite-processor.pl" or die "symlink: $!";
    symlink "$root/lazysite-auth.pl",      "$cgibin/lazysite-auth.pl"      or die "symlink: $!";

    my $sock = "$base/pool.sock";
    my $LOG  = "$base/worker-stderr.log";
    socket( my $lsock, AF_UNIX, SOCK_STREAM, 0 ) or die "socket: $!";
    bind( $lsock, sockaddr_un($sock) )           or die "bind: $!";
    listen( $lsock, 5 )                          or die "listen: $!";
    my $pid = fork() // die "fork: $!";
    if ( $pid == 0 ) {
        %ENV = ( env_passthrough(), DOCUMENT_ROOT => $d, LAZYSITE_FCGI_MAX_REQUESTS => 500,
            LAZYSITE_FRONT_DOOR => 1, LAZYSITE_CGIBIN => $cgibin, LAZYSITE_LOG_LEVEL => 'ERROR' );
        dup2( fileno($lsock), 0 ) or die "dup2: $!";
        open STDERR, '>', $LOG or die $!;
        exec $^X, "$root/lazysite-processor.pl";
        die "exec: $!";
    }
    close $lsock;

    my $req = sub {
        my ($cookie) = @_;
        my $r = MiniFcgi::fcgi_request( $sock,
            {   REQUEST_METHOD => 'GET', REMOTE_ADDR => '198.51.100.1', HTTP_HOST => 'site.test',
                DOCUMENT_ROOT  => $d, REDIRECT_URL => '/', REQUEST_URI => '/', QUERY_STRING => '',
                ( defined $cookie ? ( HTTP_COOKIE => $cookie ) : () ) } );
        return $r->{stdout} // '';
    };

    my $up;
    for ( 1 .. 50 ) {
        $up = eval { $req->(undef) };
        last if $up && $up =~ /HOME BODY/;
        select( undef, undef, undef, 0.1 );
    }

    subtest 'the pool' => sub {
        like( $up // '', qr/HOME BODY/, 'the one-worker pool is up with the front door on' )
            or return diag( slurp($LOG) );
        check_all( $req, 'pool' );
    };
    kill 'TERM', $pid;
    waitpid $pid, 0;
}

done_testing();
