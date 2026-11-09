#!/usr/bin/perl
# Rulings 206, 216 and 217 (n795, the 0.16.9 restack): A REQUEST REFUSED BECAUSE A
# STORE CANNOT BE TOLD GETS ONE REFUSAL, IN ONE WORDING, ON EVERY PATH.
#
# Three branches each built a refusal for a damaged store: SM297's for a session
# cookie whose store cannot be read (the auth wrapper on the CGI path, the front
# door in the pool), n789's _store_fault_gate (a rejected content_root, or a
# signed-in request while the group store cannot be read) and n790's manager door
# (item 18). They said three different things, and two of them named a file to
# the visitor. Now each is the processor's one _serve_store_fault, or, in the
# auth wrapper (its own program), the same sentence from the same function:
# Lazysite::Auth::Session::store_fault_text. 503, the same words, no file named;
# the log names the store and the repair.
#
# What does not change: a session cookie on an unreadable store gets 503; a
# request with no cookie is served as usual.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use POSIX       qw(dup2);
use Socket      qw(AF_UNIX SOCK_STREAM sockaddr_un);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir run_child processor_path);
use Lazysite::Auth::Session ();

my $root  = repo_root();
# The one wording. Asked through eval so that, with the fix reverted, the paths
# below still run and show their own words.
my $WORDS = eval { Lazysite::Auth::Session::store_fault_text() } // q{};
my %SAID;    # path => the body it answered

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

sub site {
    my (%o) = @_;
    my $d = site_tempdir();
    spit( "$d/lazysite/lazysite.conf", "site_name: T\nmanager: enabled\n" . ( $o{conf} // '' ) );
    spit( "$d/lazysite/auth/.secret", "$SECRET\n" );
    chmod 0600, "$d/lazysite/auth/.secret";
    spit( "$d/lazysite/auth/users",              "alice:x\n" );
    spit( "$d/lazysite/auth/groups",             "editors: alice\n" );
    spit( "$d/lazysite/auth/user-settings.json", "{}\n" );
    spit( "$d/lazysite/auth/groups-settings.json", '{"editors":{"label":"Editors","ui":1}}' );
    spit( "$d/index.md", "---\ntitle: Home\n---\nHOME BODY\n" );
    return $d;
}

sub cookie_for {
    my ($user) = @_;
    my $payload = "$user:" . time() . ':';
    return 'lazysite_auth=' . $payload . ':' . hmac_sha256_hex( $payload, $SECRET );
}

sub split_response {
    my ($out) = @_;
    my ( $head, $body ) = split /\r?\n\r?\n/, ( $out // '' ), 2;
    my ($status) = ( $head // '' ) =~ /^Status:\s*(\d{3})/m;
    return ( $status // 200, $body // '' );
}

# The refusal, whichever path gave it.
sub one_refusal_ok {
    my ( $out, $what ) = @_;
    my ( $status, $body ) = split_response($out);
    is( $status, 503, "$what: 503" ) or diag( substr $out, 0, 600 );
    $SAID{$what} = $body;
    is( $body, $WORDS, "$what: the one wording" );
    unlike( $body, qr{lazysite/|\.json|users\b}, "$what: naming no file to the visitor" );
    return;
}

# The auth wrapper (the CGI path), with or without a cookie.
sub via_wrapper {
    my ( $d, $cookie, $uri ) = @_;
    $uri //= '/';
    my $err = "$d/../wrapper-stderr.log";
    local %ENV = ( env_passthrough(), DOCUMENT_ROOT => $d, REQUEST_METHOD => 'GET',
        REDIRECT_URL => $uri, REQUEST_URI => $uri, QUERY_STRING => '', REMOTE_ADDR => '198.51.100.1',
        HTTP_HOST => 'site.test', LAZYSITE_PROCESSOR => "$root/lazysite-processor.pl",
        LAZYSITE_LOG_LEVEL => 'WARN', ( defined $cookie ? ( HTTP_COOKIE => $cookie ) : () ) );
    my $out = qx(\Q$^X\E \Q$root/lazysite-auth.pl\E 2>\Q$err\E);
    return ( $out, slurp($err) );
}

# The processor behind the wrapper, the wrapper vouching for the user.
sub via_processor {
    my ( $d, $uri, $user ) = @_;
    local %ENV = ( %ENV, DOCUMENT_ROOT => $d, REDIRECT_URL => $uri, REQUEST_METHOD => 'GET',
        QUERY_STRING => '', HTTP_HOST => 'site.test',
        ( defined $user ? ( LAZYSITE_AUTH_TRUSTED => 1, HTTP_X_REMOTE_USER => $user,
                HTTP_X_REMOTE_GROUPS => 'editors' ) : () ) );
    my $r = run_child( [ $^X, processor_path() ], stderr => 'pipe' );
    return ( $r->{out}, $r->{err} // '' );
}

subtest 'a session cookie on an unreadable session store, through the auth wrapper' => sub {
    my $d = site();
    spit( "$d/lazysite/auth/user-settings.json", '{ not json' );
    my ( $out, $log ) = via_wrapper( $d, cookie_for('alice') );
    one_refusal_ok( $out, 'the CGI wrapper' );
    like( $log, qr/store=lazysite\/auth\/user-settings\.json/, 'the log names the store' );
    like( $log, qr/repair=lazysite check/, 'and the repair' );
    my ($none) = via_wrapper( $d, undef );
    like( $none, qr/HOME BODY/, 'no session cookie: served as usual' );
};

subtest 'a signed-in request while the group store cannot be read (the gate)' => sub {
    my $d = site();
    spit( "$d/lazysite/auth/groups-settings.json", '{"editors": {"ui": 1' );
    my ( $out, $log ) = via_processor( $d, '/', 'alice' );
    one_refusal_ok( $out, 'the store-fault gate' );
    like( $log, qr/store=lazysite\/auth\/groups-settings\.json/, 'the log names the store' );
    my ($anon) = via_processor( $d, '/' );
    like( $anon, qr/HOME BODY/, 'an anonymous visitor is served as usual' );
};

subtest 'the manager door, on the same fault' => sub {
    my $d = site();
    spit( "$d/lazysite/auth/groups-settings.json", '{"editors": {"ui": 1' );
    my ( $out, $log ) = via_processor( $d, '/manager/', 'alice' );
    one_refusal_ok( $out, 'the manager door' );
    unlike( $out, qr/Manager access not permitted|grant your group/, 'never the sentence about a grant' );
};

subtest 'a host whose content_root is rejected' => sub {
    my $d = site( conf => "content_root: sites/not-there\n" );
    my ( $out, $log ) = via_processor( $d, '/' );
    one_refusal_ok( $out, 'the rejected content_root' );
    like( $log, qr/store=lazysite\/lazysite\.conf/, 'the log names the store' );
};

SKIP: {
    skip 'FCGI.pm not installed (the plain-CGI path is the fallback)', 1 unless eval { require FCGI; 1 };
    require MiniFcgi;
    my $d = site();
    ( my $base = $d ) =~ s{/[^/]+\z}{};
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
            LAZYSITE_FRONT_DOOR => 1, LAZYSITE_CGIBIN => $cgibin, LAZYSITE_LOG_LEVEL => 'WARN' );
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
    subtest 'a session cookie on an unreadable session store, in the pool' => sub {
        like( $up // '', qr/HOME BODY/, 'the pool is up' ) or return diag( slurp($LOG) );
        spit( "$d/lazysite/auth/user-settings.json", '{ not json' );
        my $out  = $req->( cookie_for('alice') );
        my $none = $req->(undef);
        one_refusal_ok( $out, 'the front door' );
        like( $none, qr/HOME BODY/, 'no session cookie: served as usual' );
        unlike( slurp($LOG), qr/isn't numeric/, 'the access record takes the status as a number' );
    };
    kill 'TERM', $pid;
    waitpid $pid, 0;
}

subtest 'every path says the same words' => sub {
    my %words = map { $_ => 1 } values %SAID;
    cmp_ok( scalar keys %SAID, '>=', 4, 'at least four paths answered' );
    is( scalar keys %words, 1, 'one wording across them' ) or diag explain \%SAID;
};

done_testing();
