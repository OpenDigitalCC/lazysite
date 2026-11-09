#!/usr/bin/perl
# SM297 (ruling 206, ruling 217): A PAGE REQUEST CARRYING A SESSION COOKIE WHOSE
# SESSION STORE CANNOT BE READ IS REFUSED - 503, NAMING THE STORE AND THE REPAIR -
# AND NEVER RENDERED AS ANONYMOUS, ON BOTH PATHS.
#
#   the pool    the front door decides the identity in the worker (SM1181 S3);
#               request_session's fault value (`cannot-tell`, with the store) is
#               answered there with a 503;
#   the CGI     the auth wrapper refuses before it execs the processor.
#
# Controls: a request with no session cookie is served as usual; an expired cookie
# and a cookie for a removed account are ordinary signed-out visitors (not a fault);
# once the store is repaired the same cookie is served again.
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

my $SECRET = 'e' x 64;
spit( "$LZ/lazysite.conf", "site_name: T\n" );
spit( "$LZ/auth/.secret",  "$SECRET\n" );
chmod 0600, "$LZ/auth/.secret";
spit( "$LZ/auth/users", "alice:x\n" );
spit( "$LZ/auth/user-settings.json", "{}\n" );
spit( "$d/index.md", "---\ntitle: Home\n---\nHOME BODY\n" );

my $STORE = "$LZ/auth/user-settings.json";
my $GOOD  = slurp($STORE);
sub break_store  { spit( $STORE, '{ not json' ); return }
sub repair_store { spit( $STORE, $GOOD );        return }

# A legacy three-field cookie (user:ts:groups), signed with the site secret.
sub cookie_for {
    my ( $user, %o ) = @_;
    my $payload = "$user:" . ( $o{ts} // time() ) . ':';
    return 'lazysite_auth=' . $payload . ':' . hmac_sha256_hex( $payload, $SECRET );
}
my $EXPIRED = cookie_for( 'alice', ts => time() - 30 * 86400 );

sub refused_ok {
    my ( $out, $log, $what ) = @_;
    like( $out, qr/\AStatus: 503/, "$what: a 503" ) or diag($out);
    like( $out, qr{lazysite/auth/user-settings\.json}, "$what: the response names the store" );
    like( $out, qr/lazysite check/, "$what: and the remedy" );
    unlike( $out, qr/HOME BODY/, "$what: the page is never rendered as anonymous" );
    like( $log, qr/cannot tell - session refused[^\n]*store=lazysite\/auth\/user-settings\.json/,
        "$what: the refusal's log line names the store" ) or diag($log);
    like( $log, qr/cannot tell - session refused[^\n]*repair=lazysite check/, "$what: and the repair" );
    unlike( $log, qr/isn't numeric/, "$what: and the access record takes the status as a number" );
    return;
}

# --- the CGI path: the auth wrapper ----------------------------------------------

sub via_wrapper {
    my ($cookie) = @_;
    my $err = "$base/wrapper-stderr.log";
    local %ENV = ( env_passthrough(), DOCUMENT_ROOT => $d, REQUEST_METHOD => 'GET',
        REDIRECT_URL => '/', REQUEST_URI => '/', QUERY_STRING => '', REMOTE_ADDR => '198.51.100.1',
        HTTP_HOST => 'site.test', LAZYSITE_PROCESSOR => "$root/lazysite-processor.pl",
        LAZYSITE_LOG_LEVEL => 'WARN', ( defined $cookie ? ( HTTP_COOKIE => $cookie ) : () ) );
    my $out = qx(\Q$^X\E \Q$root/lazysite-auth.pl\E 2>\Q$err\E);
    return ( $out, slurp($err) );
}

subtest 'the CGI wrapper refuses a session whose store cannot be read' => sub {
    my ($ok) = via_wrapper( cookie_for('alice') );
    like( $ok, qr/HOME BODY/, 'with the store readable, the signed-in page is served' );
    break_store();
    my ( $out, $log ) = via_wrapper( cookie_for('alice') );
    my ($none) = via_wrapper(undef);
    my ($exp)  = via_wrapper($EXPIRED);
    my ($gone) = via_wrapper( cookie_for('removed') );
    repair_store();
    refused_ok( $out, $log, 'CGI' );
    like( $none, qr/HOME BODY/, 'no session cookie: served as usual' );
    like( $exp,  qr/HOME BODY/, 'an expired cookie: an ordinary signed-out visitor' );
    like( $gone, qr/HOME BODY/, 'a cookie for a removed account: an ordinary signed-out visitor' );
    my ($again) = via_wrapper( cookie_for('alice') );
    like( $again, qr/HOME BODY/, 'repaired, the same cookie is served again' );
};

# --- the pool: the front door in the worker --------------------------------------

SKIP: {
    skip 'FCGI.pm not installed (the plain-CGI path is the fallback)', 1 unless eval { require FCGI; 1 };
    require MiniFcgi;
    my $cgibin = "$base/cgi-bin";
    my $RAN    = "$base/wrapper-ran.log";
    make_path($cgibin);
    symlink "$root/lazysite-processor.pl", "$cgibin/lazysite-processor.pl" or die "symlink: $!";
    spit( "$cgibin/lazysite-auth.pl", <<"PERL" );
#!/usr/bin/perl
open my \$fh, '>>', '$RAN' or die;
print {\$fh} "ran\\n";
close \$fh;
exec \$^X, '$root/lazysite-auth.pl';
PERL

    my $sock = "$base/pool.sock";
    my $LOG  = "$base/worker-stderr.log";
    socket( my $lsock, AF_UNIX, SOCK_STREAM, 0 ) or die "socket: $!";
    bind( $lsock, sockaddr_un($sock) )           or die "bind: $!";
    listen( $lsock, 5 )                          or die "listen: $!";
    my $pid = fork() // die "fork: $!";
    if ( $pid == 0 ) {
        %ENV = ( env_passthrough(), DOCUMENT_ROOT => $d, LAZYSITE_FCGI_MAX_REQUESTS => 500,
            LAZYSITE_FRONT_DOOR => 1, LAZYSITE_CGIBIN => $cgibin, LAZYSITE_LOG_LEVEL => 'WARN' );
        dup2( fileno($lsock), 0 ) or die "dup2: $!";
        open STDERR, '>', $LOG or die $!;
        exec $^X, "$root/lazysite-processor.pl";
        die "exec: $!";
    }
    close $lsock;

    my $req = sub {
        my ($cookie) = @_;
        my $log0 = length slurp($LOG);
        my $r    = MiniFcgi::fcgi_request( $sock,
            {   REQUEST_METHOD => 'GET', REMOTE_ADDR => '198.51.100.1', HTTP_HOST => 'site.test',
                DOCUMENT_ROOT  => $d, REDIRECT_URL => '/', REQUEST_URI => '/', QUERY_STRING => '',
                ( defined $cookie ? ( HTTP_COOKIE => $cookie ) : () ) } );
        return ( $r->{stdout} // '', ( $r->{stderr} // '' ) . substr( slurp($LOG), $log0 ) );
    };

    my $up;
    for ( 1 .. 50 ) {
        ($up) = eval { $req->(undef) };
        last if $up && $up =~ /HOME BODY/;
        select( undef, undef, undef, 0.1 );
    }

    subtest 'the pool refuses it in the worker' => sub {
        like( $up // '', qr/HOME BODY/, 'the one-worker pool is up with the front door on' )
            or return diag( slurp($LOG) );
        my ($ok) = $req->( cookie_for('alice') );
        like( $ok, qr/HOME BODY/, 'with the store readable, the signed-in page is served' );
        break_store();
        my ( $out, $log ) = $req->( cookie_for('alice') );
        my ($none) = $req->(undef);
        my ($exp)  = $req->($EXPIRED);
        my ($gone) = $req->( cookie_for('removed') );
        repair_store();
        refused_ok( $out, $log, 'pool' );
        is( slurp($RAN), '', 'decided in the worker: the auth wrapper never ran' );
        like( $none, qr/HOME BODY/, 'no session cookie: served as usual' );
        like( $exp,  qr/HOME BODY/, 'an expired cookie: an ordinary signed-out visitor' );
        like( $gone, qr/HOME BODY/, 'a cookie for a removed account: an ordinary signed-out visitor' );
        my ($again) = $req->( cookie_for('alice') );
        like( $again, qr/HOME BODY/, 'repaired, the same cookie is served again by the same worker' );
    };
    kill 'TERM', $pid;
    waitpid $pid, 0;
}

done_testing();
