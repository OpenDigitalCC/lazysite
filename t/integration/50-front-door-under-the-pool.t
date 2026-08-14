#!/usr/bin/perl
# SM294: the front door works inside the FastCGI pool, and the worker survives it.
#
# WHERE SM293 LEFT IT. Step 5 shipped `Lazysite::FrontDoor::route()` plus a CGI
# that executes the decision, so a front end can be one rule. That CGI dispatches
# by exec(), which is right for a one-shot process and fatal inside a persistent
# worker: exec REPLACES the process, so the worker handling the request would
# cease to exist and the next request would find nothing listening. So an
# operator had to choose between one rule they could reason about and throughput.
#
# WHAT THIS PINS. With LAZYSITE_FRONT_DOOR=1 the pool worker consults the same
# routing table and:
#
#   - handles the hot path IN-PROCESS at no cost (a page render, a denial) -
#     this is the overwhelming majority of requests and the whole point;
#   - RELAYS the cold path (another CGI surface, or anything needing the auth
#     wrapper) by forking a child, which costs a process on exactly the requests
#     that cost one today, and never replaces the worker.
#
# THE REGRESSION THIS EXISTS TO CATCH is the one the filing names: a dispatcher
# that execs from inside the accept loop. That failure is INVISIBLE to a
# single-request test - the first request is answered perfectly and the worker is
# simply gone afterwards. So every case below is followed by another request, and
# the last subtest asserts the SAME worker pid served all of them.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use POSIX      qw(dup2);
use Socket     qw(AF_UNIX SOCK_STREAM sockaddr_un);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough);
use MiniFcgi   qw(fcgi_request);

plan skip_all => 'FCGI.pm not installed (the plain-CGI path is the fallback)'
    unless eval { require FCGI; 1 };

my $root = repo_root();
my $base = tempdir( CLEANUP => 1 );
my $d    = "$base/public_html";
make_path("$d/lazysite/auth");

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
spit( "$d/index.md",               "---\ntitle: Home\n---\nHOME BODY\n" );
spit( "$d/logo.png",               "PNGBYTES\n" );

# A cgi-bin of SYMLINKS to the real surfaces. The surfaces bootstrap @INC from
# Cwd::abs_path(__FILE__), which resolves the symlink back to the repo, so they
# find their own lib - while leaving us a directory we can also drop a probe in.
my $cgibin = "$base/cgi-bin";
make_path($cgibin);
for my $s (qw(lazysite-processor.pl lazysite-auth.pl lazysite-mcp.pl)) {
    symlink "$root/$s", "$cgibin/$s" or die "symlink $s: $!";
}

# A probe CGI, so the RELAY CONTRACT is tested directly rather than inferred from
# another surface's behaviour: it reports the method and path it was handed, and
# echoes its request body back. Named lazysite-*.pl because that is the shape
# route() dispatches by name.
spit( "$cgibin/lazysite-relay-probe.pl", <<'PROBE' );
#!/usr/bin/perl
use strict;
use warnings;
my $body = do { local $/; <STDIN> };
$body = '' unless defined $body;
print "Status: 202 Accepted\r\n";
print "Content-Type: text/plain; charset=utf-8\r\n";
print "X-Probe-Pid: $$\r\n\r\n";
print "METHOD=$ENV{REQUEST_METHOD}\n";
print "URI=", ( $ENV{REDIRECT_URL} // $ENV{REQUEST_URI} // '-' ), "\n";
print "DOCROOT=$ENV{DOCUMENT_ROOT}\n";
print "BODY=$body\n";
PROBE
chmod 0755, "$cgibin/lazysite-relay-probe.pl";

# --- spawn the pool worker, front door ON -------------------------------------
my $sock_path = "$base/fcgi.sock";
socket( my $lsock, AF_UNIX, SOCK_STREAM, 0 ) or die "socket: $!";
bind( $lsock, sockaddr_un($sock_path) )      or die "bind: $!";
listen( $lsock, 5 )                          or die "listen: $!";

my $pid = fork();
die "fork: $!" unless defined $pid;
if ( $pid == 0 ) {
    my %keep = (
        env_passthrough(),
        DOCUMENT_ROOT              => $d,
        LAZYSITE_FCGI_MAX_REQUESTS => 100,
        LAZYSITE_FRONT_DOOR        => 1,
        LAZYSITE_CGIBIN            => $cgibin,
    );
    %ENV = %keep;
    dup2( fileno($lsock), 0 ) or die "dup2: $!";
    open STDERR, '>', "$base/worker-stderr.log" or die $!;
    exec $^X, "$root/lazysite-processor.pl";
    die "exec: $!";
}
close $lsock;

sub req {
    my ( $params, $body ) = @_;
    return fcgi_request(
        $sock_path,
        { REQUEST_METHOD => 'GET',
            REMOTE_ADDR     => '198.51.100.1',
            HTTP_USER_AGENT => 'Mozilla/5.0 FrontDoorTest',
            DOCUMENT_ROOT   => $d,
            %{$params},
        },
        $body
    );
}

my $up;
for ( 1 .. 50 ) {
    $up = eval { req( { REDIRECT_URL => '/' } ) };
    last if $up;
    select( undef, undef, undef, 0.1 );
}
ok( $up, 'worker up with the front door enabled' ) or do {
    kill 'TERM', $pid;
    diag( do { open my $fh, '<', "$base/worker-stderr.log"; local $/; <$fh> } );
    done_testing;
    exit;
};

subtest 'the hot path is handled in-process, exactly as before' => sub {
    like( $up->{stdout}, qr/Status: 200 OK/, 'a page renders' );
    like( $up->{stdout}, qr/HOME BODY/,      'with its content' );

    my $miss = req( { REDIRECT_URL => '/nope' } );
    like( $miss->{stdout}, qr/Status: 404 Not Found/,
        'and a miss is still the engine 404, not the front door inventing one' );
};

subtest 'an engine-owned path is denied in-process' => sub {
    # route() answers 'denied' for /lazysite/*, and the worker must emit that
    # itself - there is nothing to relay to.
    my $r = req( { REDIRECT_URL => '/lazysite/lazysite.conf' } );
    like( $r->{stdout}, qr/Status: 404 Not Found/,
        '404 rather than 403: a 403 confirms the path exists' );
    unlike( $r->{stdout}, qr/site_name/,
        'and the config bytes do not appear in the response' );
};

subtest 'a named CGI surface is RELAYED, and the worker lives' => sub {
    my $r = req(
        { REDIRECT_URL => '/cgi-bin/lazysite-relay-probe.pl',
            REQUEST_URI    => '/cgi-bin/lazysite-relay-probe.pl',
            REQUEST_METHOD => 'POST',
            CONTENT_TYPE   => 'text/plain',
            CONTENT_LENGTH => 10,
        },
        'HELLOBYTES'
    );

    like( $r->{stdout}, qr/Status: 202 Accepted/,
        'the probe answered, so the request really reached another program' );
    like( $r->{stdout}, qr/METHOD=POST/, 'the method crossed' );
    like( $r->{stdout}, qr{URI=/cgi-bin/lazysite-relay-probe\.pl},
        'the path crossed' );
    like( $r->{stdout}, qr/\QDOCROOT=$d\E/, 'the docroot crossed' );
    like( $r->{stdout}, qr/BODY=HELLOBYTES/,
        'and the request BODY crossed - the pipe is pumped both ways' );

    my ($probe_pid) = $r->{stdout} =~ /X-Probe-Pid: (\d+)/;
    isnt( $probe_pid, $pid,
        'the probe ran in a CHILD, not by replacing the worker' );

    my $after = req( { REDIRECT_URL => '/' } );
    like( $after->{stdout}, qr/HOME BODY/,
        'and the worker answers the NEXT request - which an exec() dispatcher '
            . 'could not, because it would no longer exist' );
};

subtest 'a real surface relays too' => sub {
    # The probe proves the mechanism; this proves it is wired to the surfaces an
    # operator actually reaches, and that the response is the surface's own
    # rather than the engine rendering a page called /cgi-bin/...
    my $r = req(
        { REDIRECT_URL => '/cgi-bin/lazysite-mcp.pl',
            REQUEST_URI => '/cgi-bin/lazysite-mcp.pl',
        }
    );
    unlike( $r->{stdout}, qr/HOME BODY/,
        'the processor did not render it as a page' );
    unlike( $r->{stdout}, qr/Page not found/,
        'and did not 404 it as a missing page, which is what happens when the '
            . 'front door is not consulted at all - the check that makes this '
            . 'subtest fail before the feature exists' );
    ok( length $r->{stdout}, 'the surface answered something' );

    like( req( { REDIRECT_URL => '/' } )->{stdout}, qr/HOME BODY/,
        'worker still alive' );
};

subtest 'a relay to a surface that is not installed is a 500, not a hang' => sub {
    my $r = req(
        { REDIRECT_URL => '/cgi-bin/lazysite-not-installed.pl',
            REQUEST_URI => '/cgi-bin/lazysite-not-installed.pl',
        }
    );
    like( $r->{stdout}, qr/Status: 500/,
        'a missing surface is reported' );

    like( req( { REDIRECT_URL => '/' } )->{stdout}, qr/HOME BODY/,
        'and the worker survives the failure' );
};

subtest 'the worker is still the worker' => sub {
    # The direct form of the regression check. An exec() dispatcher does not
    # crash: the pid stays valid and the process stays alive, it has simply
    # BECOME the relay target. So liveness alone proves nothing - read what the
    # process is actually running.
    ok( kill( 0, $pid ), 'the worker process is alive' );

SKIP: {
        skip 'no /proc on this platform', 1 unless -r "/proc/$pid/cmdline";
        my $cmd = do {
            open my $fh, '<', "/proc/$pid/cmdline" or die $!;
            local $/;
            <$fh>;
        };
        $cmd =~ tr/\0/ /;
        like( $cmd, qr/lazysite-processor\.pl/,
            'and it is STILL running the processor - it was never replaced by '
                . 'a surface it dispatched to' )
            or diag("worker is now running: $cmd");
    }

    # The access log is per-request state; a worker that had been replaced could
    # not have kept appending to it across all of the above.
    my ($log) = glob "$d/lazysite/logs/access-*.jsonl";
    ok( $log, 'access log written' ) or return;
    my @lines = map { decode_json($_) } do {
        open my $fh, '<', $log or die $!;
        <$fh>;
    };
    cmp_ok( scalar @lines, '>=', 8,
        'every request through the front door was recorded, relays included' )
        or diag( 'lines: ' . scalar @lines );
};

kill 'TERM', $pid;
waitpid $pid, 0;

done_testing;
