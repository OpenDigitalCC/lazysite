#!/usr/bin/perl
# ADVERSARIAL (SEC-2026-07 C1, breadth pass 2026-07): a DELEGATED sub-user
# manager holds create_sub_users but NOT full manage_users. It is the classic
# confused-deputy surface - if it could grant capabilities, edit group
# membership, mint tokens, or reach accounts outside its own sub-tree, it would
# escalate to operator. This test forges each of those attempts (with a valid
# CSRF token, as a real delegate's browser would) and asserts every one is
# refused, the on-disk group file is unchanged, and the legitimate powers
# (create a sub-user in your own tree) still work - and that a real operator can
# do the things the delegate cannot (the gate is not just "deny everything").
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
    print $i encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}

# POST to the manager-API as $user (member of $groups), CSRF-signed. The auth
# wrapper sets X-Remote-* AND LAZYSITE_AUTH_TRUSTED together, so we do too.
sub post {
    my ( $d, $user, $groups, $sub ) = @_;
    my $body = encode_json($sub);
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}        = $d;
    $ENV{REQUEST_METHOD}       = 'POST';
    $ENV{QUERY_STRING}         = 'action=users';
    $ENV{CONTENT_LENGTH}       = length $body;
    $ENV{HTTP_X_REMOTE_USER}   = $user;
    $ENV{HTTP_X_REMOTE_GROUPS} = $groups;
    $ENV{HTTP_X_CSRF_TOKEN} = hmac_sha256_hex( "csrf:$user:" . int( time() / 3600 ), $secret );
    $ENV{LAZYSITE_AUTH_TRUSTED} = 1;
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    print $w $body;
    close $w;
    my $out = do { local $/; <$r> };
    close $r;
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

# --- a secured site: op = full manage_users; boss = create_sub_users only ------
my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "site_name: T\n";
close $cf;
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
print $sf $secret;
close $sf;

uapi( $d, { action => 'add', username => 'op',    password => 'x' } );
uapi( $d, { action => 'add', username => 'boss',  password => 'x' } );
uapi( $d, { action => 'add', username => 'alice', password => 'x' } );  # unrelated victim
grant_caps( $d, 'op',   'manage_users' );        # a real operator
grant_caps( $d, 'boss', 'create_sub_users' );    # a delegated sub-manager

my $BG = 'role-boss';                            # boss's capability group
my $OG = 'role-op';                              # the admin/manager group (manage_users)

# --- legitimate delegation still works (positive control) ----------------------
{
    my $r = post( $d, 'boss', $BG,
        { action => 'account-create', username => 'sub1', password => 'x' } );
    ok( $r->{ok}, 'a delegate CAN create a sub-user in its own sub-tree' )
        or diag encode_json($r);
}

# --- every escalation attempt by the delegate is refused -----------------------
my %attack = (
    'add self to the admin group' =>
        { action => 'group-add', username => 'boss', group => $OG },
    'add a victim to the admin group' =>
        { action => 'group-add', username => 'alice', group => $OG },
    'grant itself a capability directly' =>
        { action => 'settings-set', username => 'boss', key => 'manage_users', value => 1 },
    'create a top-level (un-parented) account' =>
        { action => 'add', username => 'newop', password => 'x' },
    'delete an account' =>
        { action => 'remove', username => 'alice' },
    'mint an API token for itself' =>
        { action => 'token', username => 'boss' },
);
for my $why ( sort keys %attack ) {
    my $r = post( $d, 'boss', $BG, $attack{$why} );
    ok( !$r->{ok}, "delegate CANNOT $why" ) or diag encode_json($r);
    is( $r->{kind} // '', 'forbidden', "  ... refused as forbidden ($why)" );
}

# passwd is a DELEGABLE action, but the sub-tree confinement (is_ancestor) must
# still stop the delegate resetting an account it does not own.
{
    my $r = post( $d, 'boss', $BG,
        { action => 'passwd', username => 'alice', password => 'pwned' } );
    ok( !$r->{ok},
        'delegate CANNOT reset the password of an account outside its sub-tree' )
        or diag encode_json($r);
}

# --- nothing escalated: re-read boss's real membership + resolved caps ----------
my $detail = uapi( $d, { action => 'users-detail', username => 'boss' } );
my ($boss) = grep { ( $_->{user} // '' ) eq 'boss' } @{ $detail->{users} || [] };
ok( $boss, 'boss account is still present' );
my @bgroups = @{ $boss->{settings}{groups} || [] };
ok( !( grep { $_ eq $OG } @bgroups ),
    "boss is NOT a member of the admin group ($OG) after every attempt" )
    or diag "boss groups: @bgroups";
ok( !$boss->{settings}{manage_users},
    'boss did not gain the manage_users capability through any attempt' );

# --- the gate is not "deny everything": a real operator CAN do these -----------
{
    my $r = post( $d, 'op', $OG,
        { action => 'group-add', username => 'alice', group => $OG } );
    ok( $r->{ok},
        'a full manage_users operator CAN add a user to a group (gate is capability-based, not blanket)' )
        or diag encode_json($r);
}

done_testing();
