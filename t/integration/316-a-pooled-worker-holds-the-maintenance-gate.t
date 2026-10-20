#!/usr/bin/perl
# SM1118 (ruled 2026-10-20, #338): THE MAINTENANCE GATE HOLDS IN THE ONE-RULE POOL.
#
# SM1181 moved identity into the pool worker: a page with a session cookie is no
# longer relayed to the auth wrapper, the worker decides who the request is as a
# VALUE and renders from it, and an anonymous page never meets the wrapper at all.
# A check that lived in lazysite-auth.pl, beside the bad-URL guard as the filing
# first said, would be skipped by every one of those requests. The check is the
# processor's, asked of the one identity reader, so it holds in the worker too -
# and this test is that claim, on a real FastCGI worker with the front door on:
#
#   anonymous         sent to the maintenance page (a 302), the page itself a 503
#   a signed-in holder  served, with the banner (identity decided in the worker)
#   a signed-in non-holder, a forged identity, a bad signature  sent to the page
#   a POST             refused 503, not stored
#   the sign-in page and its assets  reachable
#   per domain         one Host in maintenance, another open; the instance switch
#                      covers all
#   a request after a request  no identity or maintenance outcome carried between
#                      visitors (one worker serves them all)
use strict;
use warnings;
use Test::More;
use POSIX      qw(dup2);
use Socket     qw(AF_UNIX SOCK_STREAM sockaddr_un);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper     qw(repo_root env_passthrough);
use MaintenanceRig qw(build_site cookie_for conf_set parse_cgi slurp);
use MiniFcgi       qw(fcgi_request);

plan skip_all => 'FCGI.pm not installed (the plain-CGI path is the fallback)'
    unless eval { require FCGI; 1 };

my $root = repo_root();
my $d    = build_site( conf => "maintenance: on\nalias_hosts: a.example, b.example\n" );
( my $base = $d ) =~ s{/public_html\z}{};
my $cgibin = "$base/cgi-bin";
make_path($cgibin);
symlink "$root/lazysite-processor.pl", "$cgibin/lazysite-processor.pl" or die "symlink: $!";
symlink "$root/lazysite-auth.pl",      "$cgibin/lazysite-auth.pl" or die "symlink: $!";

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

# lazysite.conf is read per request but its site variables are keyed on the
# file's mtime in whole seconds; a test that flips the switch twice in one second
# would be served the first answer. Move the clock on instead of sleeping.
my $tick = time();
sub flip { conf_set( $d, @_ ); $tick += 5; utime $tick, $tick, "$d/lazysite/lazysite.conf"; return }

sub req {
    my ( $uri, %p ) = @_;
    my ( $path, $q ) = split /\?/, $uri, 2;
    my $r = fcgi_request( $sock,
        { REQUEST_METHOD => 'GET',
            REMOTE_ADDR     => '198.51.100.1',
            HTTP_USER_AGENT => 'Mozilla/5.0 MaintenancePoolTest',
            HTTP_HOST       => 'site.test',
            DOCUMENT_ROOT   => $d,
            REDIRECT_URL    => $path,
            REQUEST_URI     => $uri,
            QUERY_STRING    => $q // '',
            %p,
        } );
    return parse_cgi( $r->{stdout} );
}
sub as { my ( $user, $uri, %p ) = @_; return req( $uri, HTTP_COOKIE => cookie_for($user), %p ) }
sub loc { return $_[0]{headers}{location} // '' }

my $up;
for ( 1 .. 50 ) {
    $up = eval { req('/maintenance') };
    last if $up && $up->{code};
    select( undef, undef, undef, 0.1 );
}
ok( $up && $up->{code}, 'the one-worker pool is up with the front door on' )
    or do { diag( slurp($LOG) ); kill 'TERM', $pid; waitpid $pid, 0; done_testing(); exit };

subtest 'an anonymous visitor' => sub {
    my $r = req('/about');
    is( $r->{code}, 302, 'is sent away' );
    like( loc($r), qr{\A/maintenance\?from=%2Fabout\z}, '...to the maintenance page, carrying where they came from' );
    like( $r->{headers}{'cache-control'} // '', qr/no-store/, '...no-store' );
    $r = req('/maintenance');
    is( $r->{code}, 503, 'the page answers 503' );
    like( $r->{headers}{'retry-after'} // '', qr/\A\d+\z/, '...with Retry-After' );
    like( $r->{body},                         qr/in maintenance/i, '...and says why' );
};

subtest 'a signed-in request is decided in the worker, as a value' => sub {
    my $r = as( 'boss', '/about' );
    is( $r->{code}, 200, 'the holder is served' );
    like( $r->{body}, qr/ABOUT BODY/,                  '...the page' );
    like( $r->{body}, qr/lazysite-maintenance-banner/, '...with the banner' );

    is( as( 'alice', '/about' )->{code}, 302, 'a signed-in member without the capability is sent away' );
    is( as( 'bob', '/about' )->{code}, 302, '...and one with no capability at all' );
    is( req('/about')->{code}, 302, 'and the next anonymous visitor is not the holder before' );
    is( as( 'boss', '/about' )->{code}, 200, 'the holder again is the holder again' );

    my $r2 = as( 'boss', '/about', HTTP_COOKIE => cookie_for( 'boss', bad_sig => 1 ) );
    is( $r2->{code}, 302, 'a bad signature is nobody' );
};

subtest 'a forged identity is not the identity' => sub {
    my %forged = (
        HTTP_X_REMOTE_USER           => 'boss',
        HTTP_X_REMOTE_GROUPS         => 'members,role-boss',
        LAZYSITE_AUTH_TRUSTED        => '1',
        HTTP_X_LAZYSITE_AUTH_TRUSTED => '1',
    );
    is( req( '/about', %forged )->{code}, 302, 'no cookie: forged headers and the sentinel get a visitor\'s answer' );
    is( as( 'bob', '/about', %forged )->{code}, 302, "bob's cookie with boss's headers is bob" );
};

subtest 'the sign-in page and its assets stay reachable' => sub {
    my $r = req('/login');
    is( $r->{code}, 200, '/login is served' );
    for my $p (qw(/logout /forgot)) {
        unlike( loc( req($p) ), qr{maintenance}, "$p does not go to the maintenance page" );
    }
    unlike( loc( req('/lazysite-assets/theme/site.css') ), qr{maintenance}, 'an asset' );
    unlike( loc( req('/.well-known/security.txt') ), qr{maintenance}, 'well-known' );
};

subtest 'a posted request is refused' => sub {
    my $r = req( '/about', REQUEST_METHOD => 'POST', CONTENT_LENGTH => 0 );
    is( $r->{code}, 503, 'a POST to a page: 503' );
    ok( $r->{headers}{'retry-after'}, '...with Retry-After' );
};

subtest 'per domain, with the instance switch covering all' => sub {
    flip( 'maintenance', 'off' );
    is( req('/about')->{code}, 200, 'off: open' );
    flip( 'alias.a.example.maintenance', 'on' );
    is( req( '/about', HTTP_HOST => 'a.example' )->{code}, 302, 'a.example in maintenance' );
    is( req( '/about', HTTP_HOST => 'b.example' )->{code}, 200, '...b.example open' );
    is( req('/about')->{code}, 200, '...the default host open' );
    is( as( 'boss', '/about', HTTP_HOST => 'a.example' )->{code}, 200, 'the holder browses a.example' );
    is( req( '/maintenance', HTTP_HOST => 'a.example' )->{code}, 503, 'its page is a 503' );
    flip( 'maintenance', 'on' );
    is( req( '/about', HTTP_HOST => 'b.example' )->{code}, 302, 'the instance switch: b.example too' );
    is( req('/about')->{code}, 302, '...and the default host' );
};

kill 'TERM', $pid;
waitpid $pid, 0;
done_testing;
