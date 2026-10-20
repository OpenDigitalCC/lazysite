#!/usr/bin/perl
# SM1219 (#339): UNDER THE ONE-RULE POOL the account recorded is the identity the
# front door HELD for the request (SM1181 S3) - the value the worker verified from
# the cookie - and nothing a client typed.
#
# One worker, so every request is served by the same process, as a pooled
# visitor's next one is. Read off the visitor log the worker wrote:
#
#   a signed-in request (a valid cookie) is recorded with its account
#   an anonymous one after it is recorded with nobody (nothing held carries over)
#   a forged X-Remote-User / sentinel with no cookie records nobody
#   a forged header beside bob's cookie records bob, never the forged name
#   a cookie that does not verify (bad signature) records nobody
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use POSIX       qw(dup2);
use Socket      qw(AF_UNIX SOCK_STREAM sockaddr_un);
use JSON::PP    qw(encode_json);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir grant_caps);
use MiniFcgi   qw(fcgi_request);

plan skip_all => 'FCGI.pm not installed (the plain-CGI path is the fallback)'
    unless eval { require FCGI; 1 };

my $root = repo_root();
my $d    = site_tempdir();
( my $base = $d ) =~ s{/public_html\z}{};
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

my $SECRET = 'd' x 64;
my $CONF   = "site_name: T\nmanager: enabled\nbad_url_threshold: 3\n";
spit( "$LZ/lazysite.conf", $CONF );
spit( "$LZ/auth/.secret",  "$SECRET\n" );
chmod 0600, "$LZ/auth/.secret";
spit( "$LZ/auth/users", join '', map {"$_:x\n"} qw(alice bob) );

spit( "$d/index.md",     "---\ntitle: Home\n---\nHOME BODY\n" );
spit( "$d/members.md",   "---\ntitle: Members\nauth: required\n---\nMEMBERS WHO=[% auth_user %]\n" );
spit( "$d/staff.md",     "---\ntitle: Staff\nauth: required\nauth_groups: [staff]\n---\nSTAFF BODY\n" );
spit( "$d/paid.md",      "---\ntitle: Paid\npayment: required\npayment_amount: 1\n---\nPAID BODY\n" );
spit( "$d/wholesale.md", "---\ntitle: Trade\nauth: required\nauth_groups: [wholesale]\n---\nTRADE WHO=[% auth_user %]\n" );
spit( "$d/files/secret.txt", "SECRET BYTES\n" );
spit( "$d/broken.md", "---\ntitle: Broken\n---\nnever read\n" );
chmod 0000, "$d/broken.md";

# The cgi-bin: the real processor, a shim in the wrapper's place that records each
# run and execs the real wrapper, and a stand-in manager API that prints what the
# wrapper handed it.
my $cgibin = "$base/cgi-bin";
my $RAN    = "$base/wrapper-ran.log";
make_path($cgibin);
symlink "$root/lazysite-processor.pl", "$cgibin/lazysite-processor.pl" or die "symlink: $!";
spit( "$cgibin/lazysite-auth.pl", <<"PERL" );
#!/usr/bin/perl
open my \$fh, '>>', '$RAN' or die;
print {\$fh} ( \$ENV{REDIRECT_URL} // \$ENV{REQUEST_URI} // '-' ), "\\n";
close \$fh;
exec \$^X, '$root/lazysite-auth.pl';
PERL
spit( "$cgibin/lazysite-manager-api.pl", <<'PERL' );
#!/usr/bin/perl
print "Status: 200 OK\r\nContent-Type: text/plain\r\n\r\n";
print "API USER=", ( $ENV{HTTP_X_REMOTE_USER} // '' ), " TRUSTED=", ( $ENV{LAZYSITE_AUTH_TRUSTED} // '' ), "\n";
PERL

sub sid_for { my $h = hmac_sha256_hex( "sid-$_[0]", 'x' ); return substr( $h, 0, 16 ) }

# user:ts:sid:groups, signed with the site secret, as the wrapper mints it. The
# groups field is empty: the verifier reads them fresh (SEC-2026-07 M5).
sub cookie_for {
    my ( $user, %o ) = @_;
    my $payload = join ':', $user, time(), sid_for($user), '';
    my $sig     = $o{bad_sig} ? ( 'f' x 64 ) : hmac_sha256_hex( $payload, $SECRET );
    return "lazysite_auth=$payload:$sig";
}

my $sock = "$base/pool.sock";
my $LOG  = "$base/worker-stderr.log";
socket( my $lsock, AF_UNIX, SOCK_STREAM, 0 ) or die "socket: $!";
bind( $lsock, sockaddr_un($sock) )           or die "bind: $!";
listen( $lsock, 5 )                          or die "listen: $!";
my $pid = fork() // die "fork: $!";
if ( $pid == 0 ) {
    %ENV = ( env_passthrough(), DOCUMENT_ROOT => $d, LAZYSITE_FCGI_MAX_REQUESTS => 500,
        LAZYSITE_FRONT_DOOR => 1, LAZYSITE_CGIBIN => $cgibin );
    dup2( fileno($lsock), 0 ) or die "dup2: $!";
    open STDERR, '>', $LOG or die $!;
    exec $^X, "$root/lazysite-processor.pl";
    die "exec: $!";
}
close $lsock;

# One request. Returns the response; in list context ( response, the log lines it
# added, the wrapper runs it caused ).
sub req {
    my ( $uri, %p ) = @_;
    my ( $path, $q ) = split /\?/, $uri, 2;
    my $log0 = length slurp($LOG);
    my $ran0 = length slurp($RAN);
    my $r    = fcgi_request( $sock,
        {   REQUEST_METHOD  => 'GET',
            REMOTE_ADDR     => '198.51.100.1',
            HTTP_USER_AGENT => 'Mozilla/5.0 InWorkerTest',
            HTTP_HOST       => 'site.test',
            DOCUMENT_ROOT   => $d,
            REDIRECT_URL    => $path,
            REQUEST_URI     => $uri,
            QUERY_STRING    => $q // '',
            %p,
        } );
    my $out = $r->{stdout} // '';
    return $out unless wantarray;
    return ( $out, ( $r->{stderr} // '' ) . substr( slurp($LOG), $log0 ), substr( slurp($RAN), $ran0 ) );
}

sub as { my ( $user, $uri, %p ) = @_; return req( $uri, HTTP_COOKIE => cookie_for($user), %p ) }
sub to_login { return $_[0] =~ /^Location:\s*\S*\/login/mi ? 1 : 0 }

my $up;
for ( 1 .. 50 ) {
    $up = eval { req('/') };
    last if $up && $up =~ /HOME BODY/;
    select( undef, undef, undef, 0.1 );
}
like( $up // '', qr/HOME BODY/, 'the one-worker pool is up with the front door on' )
    or do { diag( slurp($LOG) ); kill 'TERM', $pid; waitpid $pid, 0; done_testing(); exit };

my ($today) = do { my @t = gmtime; sprintf '%04d%02d%02d', $t[5] + 1900, $t[4] + 1, $t[3] };
sub last_line {
    use JSON::PP qw(decode_json);
    my @l = grep {length} split /\n/, slurp("$LZ/logs/access-$today.jsonl");
    return decode_json( $l[-1] );
}

as( 'alice', '/members' );
is( last_line()->{u}, 'alice', 'a signed-in request is recorded with its account' );

req('/');
ok( !exists last_line()->{u}, 'the anonymous request after it names nobody' );

my %FORGED = ( HTTP_X_REMOTE_USER => 'mallory', LAZYSITE_AUTH_TRUSTED => '1', HTTP_X_LAZYSITE_AUTH_TRUSTED => '1' );
req( '/', %FORGED );
ok( !exists last_line()->{u}, 'a forged identity with no cookie records nobody' );

as( 'bob', '/members', %FORGED );
is( last_line()->{u}, 'bob', 'a forged header beside bob\'s cookie records bob' );
unlike( slurp("$LZ/logs/access-$today.jsonl"), qr/mallory/, '...and the forged name is nowhere in the log' );

req( '/', HTTP_COOKIE => cookie_for( 'alice', bad_sig => 1 ) );
ok( !exists last_line()->{u}, 'a cookie that does not verify records nobody' );

ok( kill( 0, $pid ), 'the one worker served every request above and is still running' );
kill 'TERM', $pid;
waitpid $pid, 0;
done_testing();
