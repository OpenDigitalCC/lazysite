#!/usr/bin/perl
# SM1221 (ruled 2026-10-20, "401 for signed-out"): a manager-API request with no
# identity answers 401, not 400, with the body it always had. Found by the
# 0.15.12 walk (Y4): the status said "your request is malformed" about a
# well-formed request that only lacked a sign-in.
#   - secured site, no identity: 401, ok false, "Authentication required"
#   - the same with a forged X-Remote-* (no wrapper flag): 401 too
#   - a site with no manager account: 503 (nothing to sign in as), its wording kept
#   - a wrapper-vouched request is unchanged: 200
#   - no WWW-Authenticate: the session is a cookie, not an HTTP scheme
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use IPC::Open3 qw(open3);
use Symbol     qw(gensym);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps site_tempdir);

my $root  = repo_root();
my $utool = "$root/tools/lazysite-users.pl";
my $mapi  = "$root/lazysite-manager-api.pl";

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

# ( status, headers-text, body-hash )
sub mapi {
    my ( $d, $trusted, %o ) = @_;
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{REQUEST_METHOD} = 'GET';
    $ENV{CONTENT_LENGTH} = 0;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_AUTHORIZATION)};
    $ENV{$_} = $o{$_} for keys %o;
    $ENV{LAZYSITE_AUTH_TRUSTED} = 1 if $trusted;
    my $e   = gensym;
    my $pid = open3( my $w, my $r, $e, $^X, $mapi );
    close $w;
    my $out = do { local $/; <$r> };
    close $r;
    { local $/; my $x = <$e>; close $e }
    waitpid $pid, 0;
    my ( $head, $body ) = $out =~ /\A(.*?)\r?\n\r?\n(.*)\z/s;
    my ($st) = ( $head // '' ) =~ /^Status:\s*(\d+)/m;
    return ( $st // 200, $head // '', eval { decode_json( $body // '' ) } || {} );
}

sub site {
    my $d = site_tempdir();
    make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: T\n";
    close $cf;
    open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
    print $sf 'sekret' x 6;
    close $sf;
    return $d;
}

# --- a secured site (some group grants manager access) ----------------------
my $d = site();
uapi( $d, { action => 'add', username => 'op', password => 'x-long-enough' } );
grant_caps( $d, 'op', 'manage_users' );

subtest 'signed out on a secured site is 401 with the body it had' => sub {
    my ( $st, $head, $b ) = mapi( $d, 0, QUERY_STRING => 'action=whoami' );
    is( $st, 401, 'status 401' );
    ok( !$b->{ok}, 'ok is false' );
    is( $b->{error}, 'Authentication required', 'the error wording is unchanged' );
    is( $b->{kind},  'unauthenticated',          'and the kind says which refusal it is' );
    unlike( $head, qr/^WWW-Authenticate:/mi, 'no WWW-Authenticate: the session is a cookie, not an HTTP scheme' );
};

subtest 'a forged identity is signed out too' => sub {
    my ($st) = mapi( $d, 0, QUERY_STRING => 'action=whoami',
        HTTP_X_REMOTE_USER => 'op', HTTP_X_REMOTE_GROUPS => 'role-op' );
    is( $st, 401, 'headers without the wrapper flag answer 401' );
};

subtest 'signed in is unchanged' => sub {
    my ( $st, undef, $b ) = mapi( $d, 1, QUERY_STRING => 'action=csrf-token',
        HTTP_X_REMOTE_USER => 'op', HTTP_X_REMOTE_GROUPS => 'role-op' );
    is( $st, 200, 'a wrapper-vouched request answers 200' );
    ok( $b->{ok}, 'ok' ) or diag encode_json($b);
};

subtest 'no manager account yet is 503, not 401, and keeps its wording' => sub {
    my $fresh = site();
    my ( $st, $head, $b ) = mapi( $fresh, 0, QUERY_STRING => 'action=whoami' );
    is( $st, 503, 'nothing can be signed in to, so the service is not yet available' );
    like( $b->{error} // '', qr/no manager account yet.*setup-sysop/s, 'the wording is unchanged' );
    is( $b->{kind}, 'not-set-up', 'with its own kind' );
    unlike( $head, qr/^WWW-Authenticate:/mi, 'and no WWW-Authenticate' );
};

done_testing;
