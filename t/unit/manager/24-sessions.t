#!/usr/bin/perl
# SM141 phase 1: the manager API's sessions-list / session-revoke / user-revoke.
#   - sessions-list returns LIVE sessions only (fresh, sid not revoked, at or
#     after the user's not_before) with user/ip/ua/issued/current fields, and
#     marks the caller's own session via LAZYSITE_AUTH_SID
#   - both revoke actions are gated on manage_users and audited with a real
#     target (sid prefix / username)
#   - the revocation writer prunes entries older than COOKIE_MAX
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use IPC::Open2 qw(open2);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
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
    delete $ENV{LAZYSITE_AUTH_SID};
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

sub op_get {
    my ( $d, $qs, %extra ) = @_;
    return mapi( $d, QUERY_STRING => $qs,
        HTTP_X_REMOTE_USER => 'op', HTTP_X_REMOTE_GROUPS => 'role-op', %extra );
}

sub op_post {
    my ( $d, $qs, $body ) = @_;
    return mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => $qs,
        HTTP_X_REMOTE_USER => 'op', HTTP_X_REMOTE_GROUPS => 'role-op',
        HTTP_X_CSRF_TOKEN => csrf('op'), body => $body );
}

sub read_json_file {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    local $/;
    my $raw = <$fh>;
    close $fh;
    return eval { decode_json($raw) };
}

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
make_path("$d/lazysite/logs");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "site_name: Test Site\nmanager: enabled\n";
close $cf;
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!; print $sf $secret; close $sf;

uapi( $d, { action => 'add', username => 'op',    password => 'x' } );
uapi( $d, { action => 'add', username => 'alice', password => 'y' } );
grant_caps( $d, 'op', 'ui', 'manage_users' );

# Registry fixture: op's own fresh session (A), two fresh alice sessions
# (B, E), a stale alice session (C), and an already-revoked one (D).
my $now  = time();
my %sid  = ( A => 'a' x 16, B => 'b' x 16, C => 'c' x 16, D => 'd' x 16, E => 'e' x 16 );
open my $rf, '>', "$d/lazysite/auth/sessions.jsonl" or die $!;
print $rf encode_json( { sid => $sid{A}, user => 'op',    t => $now - 100,       ip => '1.1.1.1', ua => 'UA-A' } ) . "\n";
print $rf encode_json( { sid => $sid{E}, user => 'alice', t => $now - 150,       ip => '5.5.5.5', ua => 'UA-E' } ) . "\n";
print $rf encode_json( { sid => $sid{B}, user => 'alice', t => $now - 200,       ip => '2.2.2.2', ua => 'UA-B' } ) . "\n";
print $rf encode_json( { sid => $sid{C}, user => 'alice', t => $now - 2 * 86400, ip => '3.3.3.3', ua => 'UA-C' } ) . "\n";
print $rf encode_json( { sid => $sid{D}, user => 'alice', t => $now - 300,       ip => '4.4.4.4', ua => 'UA-D' } ) . "\n";
close $rf;
open my $vf, '>', "$d/lazysite/auth/revoked.json" or die $!;
# The 'f' sid entry is ancient - a writer must prune it on its next write.
print $vf encode_json( { sids => { $sid{D} => $now - 300, ( 'f' x 16 ) => $now - 2 * 86400 },
    not_before => {} } );
close $vf;

# --- sessions-list: live entries only, current marked ------------------------
{
    my $r = op_get( $d, 'action=sessions-list', LAZYSITE_AUTH_SID => $sid{A} );
    ok( $r->{ok}, 'sessions-list: ok' );
    my @s = @{ $r->{sessions} || [] };
    is( scalar @s, 3, 'sessions-list: expired + revoked entries excluded' );
    is_deeply( [ map { $_->{sid} } @s ], [ $sid{A}, $sid{E}, $sid{B} ],
        'sessions-list: newest first; C (expired) and D (revoked) absent' );
    my ($a) = grep { $_->{sid} eq $sid{A} } @s;
    ok( $a->{current}, 'sessions-list: the caller session is marked current' );
    is( $a->{user},   'op',      'sessions-list: user field' );
    is( $a->{ip},     '1.1.1.1', 'sessions-list: ip field' );
    is( $a->{ua},     'UA-A',    'sessions-list: ua field' );
    is( $a->{issued}, $now - 100, 'sessions-list: issued field' );
    my ($b) = grep { $_->{sid} eq $sid{B} } @s;
    ok( !$b->{current}, 'sessions-list: other sessions not current' );
}

# --- gate: manage_users required ----------------------------------------------
{
    my $r = mapi( $d, QUERY_STRING => 'action=sessions-list',
        HTTP_X_REMOTE_USER => 'alice' );
    ok( !$r->{ok}, 'sessions-list: refused without manage_users' );
    is( $r->{kind}, 'forbidden', 'sessions-list: forbidden kind' );

    my $rr = mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=session-revoke',
        HTTP_X_REMOTE_USER => 'alice', HTTP_X_CSRF_TOKEN => csrf('alice'),
        body => encode_json( { sid => $sid{B} } ) );
    ok( !$rr->{ok} && ( $rr->{kind} // '' ) eq 'forbidden',
        'session-revoke: refused without manage_users' );
    my $rev = read_json_file("$d/lazysite/auth/revoked.json");
    ok( !exists $rev->{sids}{ $sid{B} }, 'refused revoke wrote nothing' );
}

# --- session-revoke: revokes one sid, audited, writer prunes -------------------
{
    my $r = op_post( $d, 'action=session-revoke', encode_json( { sid => $sid{B} } ) );
    ok( $r->{ok}, 'session-revoke: ok' );

    my $rev = read_json_file("$d/lazysite/auth/revoked.json");
    ok( exists $rev->{sids}{ $sid{B} }, 'session-revoke: sid recorded' );
    ok( !exists $rev->{sids}{ 'f' x 16 },
        'session-revoke: ancient entry pruned on write (dead anyway)' );

    my $l = op_get( $d, 'action=sessions-list', LAZYSITE_AUTH_SID => $sid{A} );
    ok( !( grep { $_->{sid} eq $sid{B} } @{ $l->{sessions} } ),
        'session-revoke: session gone from the live list' );

    open my $af, '<', "$d/lazysite/logs/audit.log" or die $!;
    my $audit = do { local $/; <$af> };
    close $af;
    like( $audit, qr/\| op \| session-revoke \| sid:b{8} \|.*\| ok \| ui/,
        'session-revoke: audited with a sid-prefix target' );
}

# --- session-revoke: input validation ------------------------------------------
{
    my $r = op_post( $d, 'action=session-revoke', encode_json( { sid => 'nope' } ) );
    ok( !$r->{ok}, 'session-revoke: malformed sid refused' );
}

# --- user-revoke: not_before set, audited, list drops the user -----------------
{
    my $r = op_post( $d, 'action=user-revoke', encode_json( { username => 'alice' } ) );
    ok( $r->{ok}, 'user-revoke: ok' );

    my $rev = read_json_file("$d/lazysite/auth/revoked.json");
    ok( $rev->{not_before}{alice} && $rev->{not_before}{alice} >= $now,
        'user-revoke: not_before recorded' );

    my $l = op_get( $d, 'action=sessions-list', LAZYSITE_AUTH_SID => $sid{A} );
    my @s = @{ $l->{sessions} || [] };
    ok( !( grep { $_->{user} eq 'alice' } @s ),
        'user-revoke: all of the user\'s sessions gone from the live list' );
    ok( ( grep { $_->{sid} eq $sid{A} } @s ), 'user-revoke: other users unaffected' );

    open my $af, '<', "$d/lazysite/logs/audit.log" or die $!;
    my $audit = do { local $/; <$af> };
    close $af;
    like( $audit, qr/\| op \| user-revoke \| alice \|.*\| ok \| ui/,
        'user-revoke: audited with the username target' );
}

done_testing();
