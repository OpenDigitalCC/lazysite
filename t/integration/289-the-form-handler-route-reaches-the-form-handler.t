#!/usr/bin/perl
# SM1182: under the one-rule templates a form POST reaches the form handler.
#
# THE FIELD REPORT (SM1181's review, "Found in passing"): "Under the one-rule
# templates /cgi-bin/form-handler.pl does not match the front door's
# lazysite-[a-z-]+.pl pattern, so it appears to fall to 'page miss' and reach
# the processor, not the form handler. Read, not tried."
#
# Tried here. install.pl links plugins/form-handler.pl (and payment-demo.pl)
# into cgi-bin as /cgi-bin/<name>.pl - no lazysite- prefix - and every native
# form posts to /cgi-bin/form-handler.pl. The one-rule template sends EVERY url
# to the front door, whose dispatch was an allow-list of lazysite-*.pl names, so
# the post fell through to the processor as a "page miss": the form was never
# delivered and the visitor got a page-not-found.
#
# The list stays an allow-list: the two linked plugin names are added by name,
# and a made-up /cgi-bin/x.pl still runs nothing.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use POSIX      qw(dup2);
use Socket     qw(AF_UNIX SOCK_STREAM sockaddr_un);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir);
use MiniFcgi   qw(fcgi_request);

plan skip_all => 'FCGI.pm not installed (the plain-CGI path is the fallback)'
    unless eval { require FCGI; 1 };

my $root = repo_root();
my $base = site_tempdir();
my $d    = "$base/public_html";
make_path("$d/lazysite/forms");

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

# cgi-bin exactly as install.pl makes it: the surfaces, plus the plugin links.
my $cgibin = "$base/cgi-bin";
make_path($cgibin);
for my $s (qw(lazysite-processor.pl lazysite-auth.pl)) {
    symlink "$root/$s", "$cgibin/$s" or die "symlink $s: $!";
}
for my $p (qw(form-handler payment-demo)) {
    symlink "$root/plugins/$p.pl", "$cgibin/$p.pl" or die "symlink $p: $!";
}
# A stray executable that is NOT on the list.
spit( "$cgibin/x.pl", "#!/usr/bin/perl\nprint \"Content-Type: text/plain\\r\\n\\r\\nRAN-X\\n\";\n" );
chmod 0755, "$cgibin/x.pl";

my $sock_path = "$base/fcgi.sock";
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
        LAZYSITE_FRONT_DOOR        => 1,
        LAZYSITE_CGIBIN            => $cgibin,
    );
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
            HTTP_USER_AGENT => 'Mozilla/5.0 FormRouteTest',
            DOCUMENT_ROOT   => $d,
            %{$params},
        },
        $body
    );
}
sub post {
    my ( $uri, $body ) = @_;
    return req(
        { REDIRECT_URL => $uri, REQUEST_URI => $uri,
            REQUEST_METHOD => 'POST',
            CONTENT_TYPE   => 'application/x-www-form-urlencoded',
            CONTENT_LENGTH => length $body,
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
    done_testing;
    exit;
};

subtest 'a form POST reaches the form handler' => sub {
    # No such form: the handler's OWN refusal comes back. The processor, handed
    # the same post as a page miss, answers with the site's 404 page instead.
    my $r = post( '/cgi-bin/form-handler.pl', '_form=no-such-form&x=1' );
    unlike( $r->{stdout}, qr/Page not found|Status: 404 Not Found/,
        'the processor did not answer it as a missing page' );
    like( $r->{stdout}, qr/"ok":0/,
        'the handler answered, in its own JSON refusal' )
        or diag( $r->{stdout} );
    like( req( { REDIRECT_URL => '/' } )->{stdout}, qr/HOME BODY/,
        'and the worker answers the next request' );
};

subtest 'a page request still reaches the processor' => sub {
    like( req( { REDIRECT_URL => '/' } )->{stdout}, qr/HOME BODY/, 'the home page renders' );
    like( req( { REDIRECT_URL => '/nope' } )->{stdout}, qr/Status: 404/, 'and a miss is the engine 404' );
};

subtest 'the other linked plugin is reached too' => sub {
    my $r = req( { REDIRECT_URL => '/cgi-bin/payment-demo.pl', REQUEST_URI => '/cgi-bin/payment-demo.pl?action=pay', QUERY_STRING => 'action=pay' } );
    like( $r->{stdout}, qr/Status: 302 Found/, 'the plugin ran (it redirects)' );
    like( $r->{stdout}, qr/Set-Cookie: lazysite_payment_demo=/, 'and set its own cookie' );
};

subtest 'a made-up cgi-bin script still runs nothing' => sub {
    my $r = req( { REDIRECT_URL => '/cgi-bin/x.pl', REQUEST_URI => '/cgi-bin/x.pl' } );
    unlike( $r->{stdout}, qr/RAN-X/, 'x.pl was not executed' );
    my $p = post( '/cgi-bin/x.pl', 'a=1' );
    unlike( $p->{stdout}, qr/RAN-X/, 'nor on a POST' );
    my $q = req( { REDIRECT_URL => '/cgi-bin/form-handler.pl.bak', REQUEST_URI => '/cgi-bin/form-handler.pl.bak' } );
    unlike( $q->{stdout}, qr/RAN-X/, 'a near-miss name is not an alias' );
};

kill 'TERM', $pid;
waitpid $pid, 0;
done_testing;
