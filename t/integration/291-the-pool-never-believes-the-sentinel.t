#!/usr/bin/perl
# SM1181 S2 (SM1082 C2, T3 and ruling R3): IN THE POOL, LAZYSITE_AUTH_TRUSTED FROM
# THE ENVIRONMENT IS NEVER BELIEVED.
#
# On plain CGI the sentinel is how the auth wrapper tells the processor it
# verified a cookie: the wrapper sets it and the six identity headers, then execs
# the processor. A pooled worker is not exec'd by anything: FCGI.pm REPLACES %ENV
# on every Accept() with the request's FastCGI parameters. The sentinel has no
# HTTP_ prefix, so a client cannot send it as a header, but anything the web
# server's configuration passes as a parameter arrives as it - and a worker that
# believed it would take the client's own X-Remote-User for a verified session.
# R3 (ruled 2026-10-19): in the pool the sentinel from %ENV is never believed; the
# only trusted producer of an identity in a worker is the value the front door
# holds (S3).
#
# Each request below carries LAZYSITE_AUTH_TRUSTED=1 as a parameter with
# X-Remote-User naming an operator, against a page that needs a sign-in. In a
# pool worker (with the front door on, the one-rule pool; and off, the split
# templates' pool) it must be anonymous: sent to sign in. The same request on
# plain CGI is the wrapper's contract and still opens the page, which is also what
# shows the fixture can tell the two apart.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use POSIX      qw(dup2);
use Socket     qw(AF_UNIX SOCK_STREAM sockaddr_un);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough run_processor site_tempdir);
use MiniFcgi   qw(fcgi_request);

plan skip_all => 'FCGI.pm not installed (the plain-CGI path is the fallback)'
    unless eval { require FCGI; 1 };

my $root = repo_root();
my $d    = site_tempdir();
( my $base = $d ) =~ s{/public_html\z}{};
make_path("$d/lazysite/auth");

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

spit( "$d/lazysite/lazysite.conf", "site_name: T\nmanager: enabled\n" );
spit( "$d/members.md", "---\ntitle: Members\nauth: required\n---\nMEMBERS WHO=[% auth_user %]\n" );
spit( "$d/index.md",   "---\ntitle: Home\n---\nHOME BODY\n" );

my $cgibin = "$base/cgi-bin";
make_path($cgibin);
symlink "$root/$_", "$cgibin/$_" or die "symlink $_: $!" for qw(lazysite-processor.pl lazysite-auth.pl);

my %FORGED = (
    LAZYSITE_AUTH_TRUSTED     => '1',
    LAZYSITE_AUTH_NO_PASSWORD => '1',
    HTTP_X_REMOTE_USER        => 'operator',
    HTTP_X_REMOTE_GROUPS      => 'operators',
);

my @workers;

sub spawn {
    my ( $tag, $front_door ) = @_;
    my $sock_path = "$base/$tag.sock";
    socket( my $lsock, AF_UNIX, SOCK_STREAM, 0 ) or die "socket: $!";
    bind( $lsock, sockaddr_un($sock_path) )      or die "bind: $!";
    listen( $lsock, 5 )                          or die "listen: $!";
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ( $pid == 0 ) {
        %ENV = (
            env_passthrough(),
            DOCUMENT_ROOT              => $d,
            LAZYSITE_FCGI_MAX_REQUESTS => 100,
            LAZYSITE_LOG_LEVEL         => 'WARN',
            ( $front_door ? ( LAZYSITE_FRONT_DOOR => 1, LAZYSITE_CGIBIN => $cgibin ) : () ),
        );
        dup2( fileno($lsock), 0 ) or die "dup2: $!";
        open STDERR, '>', "$base/$tag-stderr.log" or die $!;
        exec $^X, "$root/lazysite-processor.pl";
        die "exec: $!";
    }
    close $lsock;
    push @workers, $pid;
    return $sock_path;
}

sub req {
    my ( $sock, $params ) = @_;
    my $r = fcgi_request(
        $sock,
        {   REQUEST_METHOD  => 'GET',
            REMOTE_ADDR     => '198.51.100.1',
            HTTP_USER_AGENT => 'Mozilla/5.0 SentinelTest',
            DOCUMENT_ROOT   => $d,
            QUERY_STRING    => '',
            %{$params},
        }
    );
    return wantarray ? ( $r->{stdout} // '', $r->{stderr} // '' ) : $r->{stdout} // '';
}

sub up {
    my ($sock) = @_;
    for ( 1 .. 50 ) {
        my $r = eval { req( $sock, { REDIRECT_URL => '/' } ) };
        return 1 if $r && $r =~ /HOME BODY/;
        select( undef, undef, undef, 0.1 );
    }
    return 0;
}

sub slurp { open my $fh, '<', $_[0] or return ''; local $/; return scalar <$fh> // '' }

subtest 'plain CGI: the wrapper\'s contract opens the page, unchanged' => sub {
    my $out = run_processor( $d, '/members', %FORGED );
    like( $out, qr/MEMBERS WHO=operator/, 'the sentinel and the header are the wrapper\'s, believed on CGI' );
};

for my $case ( [ 'one-rule pool (front door on)', 'door', 1 ], [ 'split pool (front door off)', 'plain', 0 ] ) {
    my ( $label, $tag, $fd ) = @$case;
    subtest "$label: the sentinel as a parameter is not believed" => sub {
        my $sock = spawn( $tag, $fd );
        ok( up($sock), 'the worker is up' ) or do { diag( slurp("$base/$tag-stderr.log") ); return };

        my $out = req( $sock, { REDIRECT_URL => '/members', REQUEST_URI => '/members', %FORGED } );
        unlike( $out, qr/MEMBERS WHO=/, 'the members page is not served' );
        like( $out, qr/^Location:\s*\S*\/login/mi, 'the request is anonymous: it is sent to sign in' )
            or diag( substr( $out, 0, 400 ) );

        # The same worker again, so a second forged request is judged afresh.
        my ( $again, $err ) = req( $sock, { REDIRECT_URL => '/members', REQUEST_URI => '/members', %FORGED } );
        unlike( $again, qr/MEMBERS WHO=/, 'and again on the next request in the same worker' );

        like( $err . slurp("$base/$tag-stderr.log"), qr/untrusted auth header ignored/,
            'the forged header is logged as ignored, as an untrusted one is' );
    };
}

kill 'TERM', @workers;
waitpid $_, 0 for @workers;

done_testing();
