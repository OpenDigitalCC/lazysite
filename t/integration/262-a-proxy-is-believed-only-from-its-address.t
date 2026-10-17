#!/usr/bin/perl
# SM1129 (SM1128 P1-1, the hop check SM794 proposed and never built): with
# `auth_proxy_trusted: true`, the identity headers are believed only when the TCP
# peer (REMOTE_ADDR, never X-Forwarded-For) is in `auth_proxy_trusted_from`.
#
# Through the real CGIs, on every surface that reads the flag: the processor's
# page gate, the per-file ACL on a static file, and the manager API. A request
# from anywhere else is ANONYMOUS - the headers are stripped exactly as when the
# flag is off - and the log names the address. With the flag on and the list
# absent, empty or `none`, nobody is believed (fail closed, ruled in the filing).
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use JSON::PP    qw(encode_json decode_json);
use IPC::Open2  qw(open2);
use IPC::Open3  qw(open3);
use Symbol      qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root setup_auth_site run_processor site_tempdir grant_caps);

my $root = repo_root();

# A page-gate site: /protected needs any sign-in, /admins-only needs `admins`,
# and a static file under a read rule for alice. $conf_extra is appended.
sub site {
    my ($extra) = @_;
    my $d = site_tempdir();
    setup_auth_site($d);
    my $conf = "$d/lazysite/lazysite.conf";
    open my $in, '<', $conf or die $!;
    my $t = do { local $/; <$in> };
    close $in;
    $t =~ s/^auth_proxy_trusted(?:_from)?:.*\n//mg;
    $t .= $extra // '';
    open my $out, '>', $conf or die $!;
    print {$out} $t;
    close $out;

    make_path("$d/private");
    open my $s, '>', "$d/private/brief.html" or die $!;
    print {$s} '<h1>private-brief-body</h1>';
    close $s;
    open my $a, '>', "$d/lazysite/auth/acls.json" or die $!;
    print {$a} encode_json( { 'private/brief.html' => { read => ['alice'] } } );
    close $a;
    return $d;
}

my $ON   = "auth_proxy_trusted: true\n";
my %hdr  = ( HTTP_X_REMOTE_USER => 'alice', HTTP_X_REMOTE_GROUPS => 'admins' );
my $PROXY = '10.1.2.3';
my $OTHER = '203.0.113.9';

sub page {
    my ( $d, $uri, $addr, %more ) = @_;
    return run_processor( $d, $uri, REMOTE_ADDR => $addr, LAZYSITE_AUTH_TRUSTED => undef, %hdr, %more );
}

subtest 'page gate: believed from a listed address, anonymous from any other' => sub {
    my $d = site( $ON . "auth_proxy_trusted_from: 10.0.0.0/8, 192.0.2.7\n" );
    like( page( $d, '/admins-only', $PROXY ), qr/Status: 200/, 'a listed CIDR member is believed' );
    like( page( $d, '/admins-only', '192.0.2.7' ), qr/Status: 200/, 'a listed single address is believed' );
    my $no = page( $d, '/admins-only', $OTHER );
    like( $no, qr/Status: 302/, 'an unlisted peer is anonymous: sent to sign in' )
        or diag( substr( $no, 0, 300 ) );
    unlike( $no, qr/Status: 200/, 'and is not served' );
    like( page( $d, '/protected', $OTHER ), qr/Status: 302/, 'any signed-in page is closed to it too' );
    like( page( $d, '/admins-only', '10.255.255.255' ), qr/Status: 200/, 'the CIDR edge is inside' );
    like( page( $d, '/admins-only', '11.0.0.1' ), qr/Status: 302/, 'the first address past the CIDR is outside' );
};

subtest 'X-Forwarded-For does not make a peer trusted' => sub {
    my $d = site( $ON . "auth_proxy_trusted_from: 10.0.0.0/8\n" );
    my $out = page( $d, '/admins-only', $OTHER, HTTP_X_FORWARDED_FOR => $PROXY );
    like( $out, qr/Status: 302/, 'a client naming a listed address in X-Forwarded-For is still anonymous' );
};

subtest 'IPv6 list and peer' => sub {
    my $d = site( $ON . "auth_proxy_trusted_from: 2001:db8::/32\n" );
    like( page( $d, '/admins-only', '2001:db8::5' ), qr/Status: 200/, 'a peer inside the v6 range is believed' );
    like( page( $d, '/admins-only', '2001:db9::1' ), qr/Status: 302/, 'a peer outside it is not' );
    like( page( $d, '/admins-only', $PROXY ), qr/Status: 302/, 'a v4 peer is not matched by a v6 range' );
};

subtest 'flag on, list absent / empty / none / unparseable: nobody is believed (fail closed)' => sub {
    for my $case (
        [ 'absent', '' ],
        [ 'empty',  "auth_proxy_trusted_from:\n" ],
        [ 'none',   "auth_proxy_trusted_from: none\n" ],
        [ 'a typo', "auth_proxy_trusted_from: not-an-address\n" ],
        [ '/0',     "auth_proxy_trusted_from: 0.0.0.0/0\n" ],
        )
    {
        my $d = site( $ON . $case->[1] );
        for my $addr ( '127.0.0.1', $PROXY, $OTHER ) {
            like( page( $d, '/admins-only', $addr ), qr/Status: 302/, "$case->[0] list: $addr is anonymous" );
        }
    }
};

subtest 'flag off: the list alone changes nothing' => sub {
    my $d = site("auth_proxy_trusted_from: 10.0.0.0/8\n");
    like( page( $d, '/admins-only', $PROXY ), qr/Status: 302/, 'headers are stripped with the flag off, listed peer or not' );
};

subtest 'configured header names obey the same list' => sub {
    my $d = site( $ON . "auth_proxy_trusted_from: 10.0.0.0/8\nauth_header_user: Remote-User\nauth_header_groups: Remote-Groups\n" );
    my %c = ( HTTP_REMOTE_USER => 'alice', HTTP_REMOTE_GROUPS => 'admins' );
    like( run_processor( $d, '/admins-only', REMOTE_ADDR => $PROXY, LAZYSITE_AUTH_TRUSTED => undef, %c ),
        qr/Status: 200/, 'a configured name is believed from the listed peer' );
    like( run_processor( $d, '/admins-only', REMOTE_ADDR => $OTHER, LAZYSITE_AUTH_TRUSTED => undef, %c ),
        qr/Status: 302/, 'and stripped from any other' );
};

subtest 'per-file ACL: the same rule' => sub {
    my $d = site( $ON . "auth_proxy_trusted_from: 10.0.0.0/8\n" );
    my $ok = page( $d, '/private/brief', $PROXY );
    like( $ok, qr/private-brief-body/, 'alice, from the proxy, reads the file' );
    my $no = page( $d, '/private/brief', $OTHER );
    unlike( $no, qr/private-brief-body/, 'the same headers from elsewhere do not' );
    like( $no, qr/Status: 302/, 'anonymous: bounced to sign in' );
    my $d2 = site($ON);
    unlike( page( $d2, '/private/brief', $PROXY ), qr/private-brief-body/, 'no list: not served' );
};

# --- the manager API -----------------------------------------------------------
my $utool = "$root/tools/lazysite-users.pl";
sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}

sub mapi {
    my ( $d, %o ) = @_;
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{REQUEST_METHOD} = 'GET';
    $ENV{QUERY_STRING}   = 'action=csrf-token';
    $ENV{CONTENT_LENGTH} = 0;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED REMOTE_ADDR HTTP_X_FORWARDED_FOR)};
    $ENV{$_} = $o{$_} for grep { defined $o{$_} } keys %o;
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, "$root/lazysite-manager-api.pl" );
    close $w;
    my $out = do { local $/; <$r> };
    close $r;
    my $err = do { local $/; <$e> };
    close $e;
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    my $res = eval { decode_json( $jb // '' ) } // { _raw => $out };
    $res->{_stderr} = $err // '';
    return $res;
}

sub api_site {
    my ($extra) = @_;
    my $d = site_tempdir();
    make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\n$extra";
    close $cf;
    open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
    print {$sf} 'sekret' x 6;
    close $sf;
    uapi( $d, { action => 'add', username => 'op', password => 'x-long-enough' } );
    grant_caps( $d, 'op', 'manage_users' );
    return $d;
}

my %op = ( HTTP_X_REMOTE_USER => 'op', HTTP_X_REMOTE_GROUPS => 'role-op' );

subtest 'manager API: believed from the listed peer, anonymous from any other' => sub {
    my $d = api_site( $ON . "auth_proxy_trusted_from: 10.0.0.0/8\n" );
    my $ok = mapi( $d, %op, REMOTE_ADDR => $PROXY );
    ok( $ok->{ok} && $ok->{token}, 'the listed peer is believed' ) or diag encode_json($ok);
    my $no = mapi( $d, %op, REMOTE_ADDR => $OTHER );
    ok( !$no->{ok}, 'an unlisted peer is not' );
    like( $no->{error} // '', qr/Authentication required/i, 'it is unauthenticated' );
    like( $no->{_stderr}, qr/auth_proxy_trusted_from/, 'the log names the setting' );
    like( $no->{_stderr}, qr/\Q$OTHER\E/, 'and the address' );
    my $xff = mapi( $d, %op, REMOTE_ADDR => $OTHER, HTTP_X_FORWARDED_FOR => $PROXY );
    ok( !$xff->{ok}, 'X-Forwarded-For does not lend a peer its address' );
};

subtest 'manager API: flag on and no list believes nobody' => sub {
    my $d = api_site($ON);
    for my $addr ( '127.0.0.1', $PROXY ) {
        my $r = mapi( $d, %op, REMOTE_ADDR => $addr );
        ok( !$r->{ok}, "$addr is refused" ) or diag encode_json($r);
        like( $r->{_stderr}, qr/lists no address/, 'and the log says the list is empty' );
    }
};

subtest 'manager API: the wrapper sentinel is untouched by the list' => sub {
    my $d = api_site( $ON . "auth_proxy_trusted_from: 10.0.0.0/8\n" );
    my $r = mapi( $d, %op, REMOTE_ADDR => $OTHER, LAZYSITE_AUTH_TRUSTED => 1 );
    ok( $r->{ok} && $r->{token}, 'a cookie session vouched for by the wrapper still works from anywhere' )
        or diag encode_json($r);
};

done_testing();
