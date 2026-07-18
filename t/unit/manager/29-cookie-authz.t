#!/usr/bin/perl
# SEC-2026-07 (C1/H1/H2): the cookie/manager path must be capability-gated (not
# just the token path), state-changing actions must be POST (a GET bypasses
# CSRF), and the account-management action must require a user-management
# capability - a content-only account could previously reset any password.
use strict;
use warnings;
use Test::More;
use JSON::PP    qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use IPC::Open2  qw(open2);
use IPC::Open3  qw(open3);
use Symbol      qw(gensym);
use File::Path  qw(make_path);
use File::Temp  qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps);

my $root   = repo_root();
my $utool  = "$root/tools/lazysite-users.pl";
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sekret' x 6;

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p); close $i;
    my $out = do { local $/; <$o> }; close $o; waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}

sub mapi {
    my ( $d, %o ) = @_;
    my $body = delete $o{body};
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{REQUEST_METHOD} = $o{REQUEST_METHOD} || 'GET';
    $ENV{CONTENT_LENGTH} = defined $body ? length($body) : 0;
    delete $ENV{HTTP_X_REMOTE_USER};
    delete $ENV{HTTP_X_REMOTE_GROUPS};
    $ENV{$_} = $o{$_} for grep { defined $o{$_} } keys %o;
    my ( $w, $r ); my $e = gensym;
    # The auth wrapper sets X-Remote-* AND LAZYSITE_AUTH_TRUSTED together; a test that
    # simulates the authenticated path must do the same, or the manager-API trust
    # gate (correctly) strips the header as forged.
    $ENV{LAZYSITE_AUTH_TRUSTED} = 1 if length( $ENV{HTTP_X_REMOTE_USER} // '' );
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    print $w ( defined $body ? $body : '' ); close $w;
    my $out = do { local $/; <$r> }; close $r;
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}
sub csrf { hmac_sha256_hex( "csrf:$_[0]:" . int( time() / 3600 ), $secret ) }

# A user posting a state-changing action with a valid CSRF token.
sub post {
    my ( $d, $user, $groups, $qs, $obj ) = @_;
    return mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => $qs,
        HTTP_X_REMOTE_USER => $user,       HTTP_X_REMOTE_GROUPS => $groups,
        HTTP_X_CSRF_TOKEN  => csrf($user), body => encode_json( $obj // {} ) );
}

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "site_name: Test\nlayout: base\ntheme: live\n";
close $cf;
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!; print $sf $secret; close $sf;

# op = full operator (manage_users etc.); ed = content-editor only.
uapi( $d, { action => 'add', username => 'op', password => 'x' } );
grant_caps( $d, 'op', 'manage_users', 'manage_config', 'manage_content' );
uapi( $d, { action => 'add', username => 'ed', password => 'y' } );
grant_caps( $d, 'ed', 'manage_content' );

# --- H2: a state-changing action over GET is rejected -----------------------
{
    my $r = mapi( $d, REQUEST_METHOD => 'GET',
        QUERY_STRING       => 'action=config-set&key=site_name&value=GET_PWNED',
        HTTP_X_REMOTE_USER => 'ed', HTTP_X_REMOTE_GROUPS => 'ed' );
    ok( !$r->{ok}, 'H2: config-set over GET is refused' );
    like( slurp("$d/lazysite/lazysite.conf"), qr/site_name: Test/,
        'H2: the conf was not changed' );
}

# --- H1: a content-editor cannot config-set / backup / list users -----------
{
    my $r = post( $d, 'ed', 'ed', 'action=config-set',
        { key => 'site_name', value => 'POST_PWNED' } );
    ok( !$r->{ok}, 'H1: content-editor config-set is forbidden' );
    is( $r->{kind}, 'forbidden', 'H1: forbidden kind' );
    like( slurp("$d/lazysite/lazysite.conf"), qr/site_name: Test/, 'H1: conf unchanged' );

    my $b = post( $d, 'ed', 'ed', 'action=backup-create', { scope => 'content' } );
    ok( !$b->{ok}, 'H1: content-editor backup-create is forbidden' );
}

# --- C1: a content-editor cannot reset another account's password -----------
{
    my $r = post( $d, 'ed', 'ed', 'action=users',
        { action => 'passwd', username => 'op', password => 'HACKED' } );
    ok( !$r->{ok}, 'C1: content-editor cannot reach the users action' );
    is( $r->{kind}, 'forbidden', 'C1: forbidden' );
}

# --- operator still works ---------------------------------------------------
{
    my $r = post( $d, 'op', 'role-op', 'action=config-set',
        { key => 'site_name', value => 'Renamed' } );
    ok( $r->{ok}, 'operator config-set succeeds' );
    like( slurp("$d/lazysite/lazysite.conf"), qr/site_name: Renamed/, 'operator change applied' );

    my $p = post( $d, 'op', 'role-op', 'action=users',
        { action => 'passwd', username => 'ed', password => 'NewPass1' } );
    ok( $p->{ok}, 'operator can reset a password' );
}

sub slurp { open my $f, '<', $_[0] or return ''; local $/; <$f> }

done_testing();
