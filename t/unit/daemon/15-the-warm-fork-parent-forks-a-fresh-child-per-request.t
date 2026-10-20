#!/usr/bin/perl
# SM1226 (SM1082 C3, SM1164 D5): THE WARM-FORK PARENT FORKS A FRESH CHILD PER
# REQUEST, HANDS IT THE REQUEST'S ENVIRONMENT AND NOTHING ELSE, AND IS A SERVICE
# THAT IS RESTARTED WHEN THE ENGINE CHANGES ON DISK.
#
# The ruling's trade-off note, as the release manager was given it: "a preloaded
# parent forks a FRESH child per request, so no visitor's state survives into the
# next request (CGI's isolation; unlike the shared pool - SM1169's bug) ... one
# supervised parent per site, restarted on upgrade (the supervisor already does
# this for oomd)."
#
# THE ENDPOINT HERE IS A PROBE, so what the parent and the child do can be read
# directly: a script in the endpoint's shape (`exit main() if !caller`) that answers
# with its pid and its parent's, what the previous request left in a package
# variable, a request counter, its whole environment, the body it read and a
# random number. Its file scope calls rand() when it is compiled - in the PARENT -
# so a child that did not reseed would repeat its siblings' sequence. The real
# endpoint through the real pool is t/integration/325.
#
# The parent is the real program (lib/Lazysite/WarmFork.pm, exec'd in a fresh
# perl) started by the real service (Lazysite::Daemon::Service::OdooEndpoint::run),
# as lazysited starts it; the client is the one the pool's front door uses.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use JSON::PP    qw(decode_json);
use POSIX       ();
use Time::HiRes ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper                              qw(repo_root site_tempdir);
use Lazysite::WarmFork::Wire                ();
use Lazysite::Daemon::Service::OdooEndpoint ();

my $root = repo_root();
my $d    = site_tempdir( plugins => 1 );
( my $base = $d ) =~ s{/public_html\z}{};
my $LZ = "$d/lazysite";
make_path($LZ);

sub spit {
    my ( $p, $t ) = @_;
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

my $probe = "$base/probe.pl";
spit( $probe, <<'PERL' );
#!/usr/bin/perl
use strict;
use warnings;
use JSON::PP ();

# compiled in the parent: this seeds the parent's random generator
my $WARM = rand();

our $SEEN;
our $COUNT = 0;

exit main() if !caller;

sub main {
    my $q    = $ENV{QUERY_STRING} // '';
    my $body = '';
    my $len  = $ENV{CONTENT_LENGTH} || 0;
    if ( $len && $q !~ /skip=1/ ) {
        binmode STDIN;
        my $got = 0;
        while ( $got < $len ) {
            my $r = read( STDIN, $body, $len - $got, $got );
            last unless $r;
            $got += $r;
        }
    }
    die "asked to die\n" if $q =~ /die=1/;
    my $prev = $SEEN;
    $SEEN = $ENV{HTTP_X_WHO} // '';
    $COUNT++;
    binmode STDOUT;
    print "Status: 200 OK\r\nContent-Type: application/json\r\n\r\n";
    print JSON::PP->new->canonical->encode(
        { pid => $$, ppid => getppid(), prev => $prev, count => $COUNT, env => {%ENV},
            body_length => length $body, body_head => substr( $body, 0, 16 ), rand => rand() } );
    return 0;
}
1;
PERL

no warnings 'once';
$Lazysite::Daemon::Service::OdooEndpoint::SCRIPT       = $probe;
@Lazysite::Daemon::Service::OdooEndpoint::PROGRAM_ARGS = ( '--check-every', 1, '--settle', 1 );

my ($sock) = Lazysite::WarmFork::Wire::socket_for($LZ);
ok( defined $sock, 'the site has a socket path' ) or BAIL_OUT('no socket path');
like( $sock, qr{\A\Q$LZ\E/run/odoo-endpoint\.sock\z}, 'in the site\'s own lazysite/run' );

# --- the gate ------------------------------------------------------------------
subtest 'the service is wanted only while the Odoo extension is enabled' => sub {
    ok( !Lazysite::Daemon::Service::OdooEndpoint::wanted($d), 'the extension off: no process' );
    spit( "$LZ/lazysite.conf", "site_name: T\nplugins:\n  - plugins/odoo.pl\n" );
    ok( Lazysite::Daemon::Service::OdooEndpoint::wanted($d), 'the extension on: wanted' );
    my ( $long, $why ) = Lazysite::WarmFork::Wire::socket_for( '/x' . ( 'y' x 120 ) );
    ok( !defined $long, 'a socket path past the Unix limit is no socket' );
    like( $why, qr/at most 103/, '...and says why' );
};

# --- the parent, started by its service ---------------------------------------------
my @STARTED;
END { for (@STARTED) { kill 'KILL', $_ if kill 0, $_ } }

sub start_service {
    my $pid = fork() // die "fork: $!";
    if ( $pid == 0 ) {
        open STDERR, '>>', "$base/service.log";
        my $rc = eval { Lazysite::Daemon::Service::OdooEndpoint::run( docroot => $d ) };
        POSIX::_exit( defined $rc ? $rc : 1 );
    }
    push @STARTED, $pid;
    return $pid;
}

sub wait_for {
    my ( $code, $secs ) = @_;
    my $until = Time::HiRes::time() + ( $secs // 20 );
    while ( Time::HiRes::time() < $until ) {
        my $r = $code->();
        return $r if $r;
        Time::HiRes::sleep(0.05);
    }
    return 0;
}

sub answers { my $r = Lazysite::WarmFork::Wire::request( $sock, { REQUEST_METHOD => 'GET' }, '', timeout => 5 ); return $r->{complete} }

sub ask {
    my ( $p, $body ) = @_;
    my $r = Lazysite::WarmFork::Wire::request( $sock, { REQUEST_METHOD => 'GET', QUERY_STRING => '', %$p }, $body, timeout => 20 );
    my ( $head, $json ) = split /\r\n\r\n/, $r->{out} // '', 2;
    return ( ( eval { decode_json( $json // '' ) } || {} ), $r, $head // '' );
}

my $svc = start_service();
ok( wait_for( \&answers, 30 ), 'the parent answers on the socket' ) or BAIL_OUT('the warm-fork parent did not start');
is( ( stat $sock )[2] & 07777,     0600, 'the socket is the site user\'s alone' );
is( ( stat "$LZ/run" )[2] & 07777, 0700, '...in a directory only that user enters' );

subtest 'each request is a fresh child of the parent, and nothing of the last one is in it' => sub {
    my @a = map { ( ask( { HTTP_X_WHO => $_ } ) )[0] } qw(alice anon bob);
    is( scalar( grep { $_->{pid} } @a ), 3, 'three answers' ) or return diag explain \@a;
    my %pids = map { $_->{pid} => 1 } @a;
    is( scalar keys %pids, 3, 'three different processes' );
    my %ppid = map { $_->{ppid} => 1 } @a;
    is( scalar keys %ppid, 1, 'children of one parent' );
    ok( !exists $pids{ $a[0]{ppid} }, '...which is none of them' );
    is_deeply( [ map { $_->{prev} } @a ], [ undef, undef, undef ], 'no request saw what the one before it left' );
    is_deeply( [ map { $_->{count} } @a ], [ 1, 1, 1 ], 'each is the first request its process ran' );
    my %rand = map { $_->{rand} => 1 } @a;
    is( scalar keys %rand, 3, 'each child draws its own random numbers, though the parent drew one first' );
    for my $c (@a) {    # reaped by the parent within its one-second loop
        ok( wait_for( sub { !kill( 0, $c->{pid} ) }, 5 ), "child $c->{pid} has exited" );
    }
};

subtest 'the environment is the request\'s parameters, less the identity variables' => sub {
    my %sent = ( REQUEST_METHOD => 'GET', QUERY_STRING => 'q=1', HTTP_COOKIE => 'a=b', REMOTE_ADDR => '198.51.100.9',
        HTTP_X_WHO => 'carol' );
    my %forged = ( HTTP_X_REMOTE_USER => 'boss', HTTP_X_REMOTE_GROUPS => 'admins', HTTP_X_REMOTE_NAME => 'Boss',
        HTTP_X_REMOTE_EMAIL => 'boss@example.test', HTTP_X_PAYMENT_VERIFIED => 1, HTTP_X_PAYMENT_PAYER => 'boss',
        LAZYSITE_AUTH_TRUSTED => 1, LAZYSITE_AUTH_SID => 'forged-sid', LAZYSITE_AUTH_NO_PASSWORD => 1 );
    my ($a) = ask( { %sent, %forged } );
    is_deeply( $a->{env}, \%sent, 'exactly what was sent, with every identity variable gone' )
        or diag explain $a->{env};
};

subtest 'the body is read as the endpoint reads it, and an unread one does not hang anyone' => sub {
    my $big = join '', map { chr( 65 + $_ % 26 ) } 1 .. 300_000;
    my ($a) = ask( { REQUEST_METHOD => 'POST', CONTENT_LENGTH => length $big }, $big );
    is( $a->{body_length}, length $big, 'a body of many records reaches the endpoint whole' );
    is( $a->{body_head}, substr( $big, 0, 16 ), '...in order' );
    my $huge = 'x' x 3_000_000;
    my ( $b, $r ) = ask( { REQUEST_METHOD => 'POST', CONTENT_LENGTH => length $huge, QUERY_STRING => 'skip=1' }, $huge );
    ok( $r->{complete}, 'an endpoint that answers without reading a large body still answers' );
    is( $b->{body_length}, 0, '...having read none of it' );
};

subtest 'an endpoint that dies is a 500, and the next request is unaffected' => sub {
    my ( $a, $r, $head ) = ask( { QUERY_STRING => 'die=1' } );
    like( $head, qr/\AStatus: 500/, 'a 500 from the child' );
    my ($b) = ask( { HTTP_X_WHO => 'dave' } );
    is( $b->{count}, 1, 'and the next child is fresh' );
};

subtest 'a role other than responder is refused' => sub {
    use Socket qw(AF_UNIX SOCK_STREAM sockaddr_un);
    socket( my $s, AF_UNIX, SOCK_STREAM, 0 ) or die;
    connect( $s, sockaddr_un($sock) )        or die;
    syswrite( $s, Lazysite::WarmFork::Wire::record( 1, pack( 'nCx5', 2, 0 ) ) ); # AUTHORIZER
    my $in    = '';
    my $until = time + 5;
    while ( time < $until ) { my $n = sysread( $s, $in, 64, length $in ); last unless $n; last if length $in >= 16 }
    my ( undef, $type ) = unpack 'CC', $in;
    is( $type,                               3, 'END_REQUEST' );
    is( unpack( 'C', substr( $in, 12, 1 ) ), 3, '...with UNKNOWN_ROLE' );
};

subtest 'the parent is restarted when a file it loaded changes on disk' => sub {
    my ($before) = ask( {} );
    open my $fh, '>>', $probe or die;
    print {$fh} "# an upgrade\n";
    close $fh;
    my $after = wait_for( sub { my ($a) = ask( {} ); ( $a->{ppid} && $a->{ppid} != $before->{ppid} ) ? $a : 0 }, 20 );
    ok( $after, 'a new parent answers' );
    ok( !kill( 0, $before->{ppid} ), '...and the old one has gone' );
    ok( kill( 0,  $svc ), 'the service itself kept running (a restart, not a failure)' );
    my $log = do { open my $l, '<', "$base/service.log"; local $/; <$l> // '' };
    like( $log, qr/restarted for a changed engine/, 'the service says why' );
};

subtest 'a parent whose service is gone stops, and takes its socket with it' => sub {
    my ($a) = ask( {} );
    kill 'KILL', $svc;
    waitpid $svc, 0;
    ok( wait_for( sub { !kill( 0, $a->{ppid} ) }, 10 ), 'the orphaned parent exits' );
    ok( wait_for( sub { !-e $sock },              5 ),  'its socket is removed' );
};

subtest 'SIGTERM to the service stops the parent' => sub {
    my $s2 = start_service();
    ok( wait_for( \&answers, 30 ), 'started again' );
    my ($a) = ask( {} );
    kill 'TERM', $s2;
    my $rc;
    wait_for( sub { my $k = waitpid( $s2, POSIX::WNOHANG() ); $rc = $? >> 8 if $k == $s2; $k == $s2 }, 20 );
    is( $rc, 0, 'the service exits 0' );
    ok( !kill( 0, $a->{ppid} ), 'the parent is gone' );
    ok( !-e $sock,              'and so is the socket' );
};

done_testing;
