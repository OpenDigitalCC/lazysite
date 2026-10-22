#!/usr/bin/perl
# SM1070 (n562, ruled 2026-10-13 "Probe, then fix"): removing an account signs
# out every one of its sessions, the way SM1040 does for a password change - a
# not_before for the name in revoked.json, which ends legacy cookies too.
#
# The verifier now also refuses a session whose account is not in the store
# (t/unit/auth/55). The revocation is the other half and is not redundant: a NEW
# account created under the removed name would otherwise inherit every cookie
# the old one left behind, because a cookie names an account by its name. The
# same holds for a rename, which frees the old name.
#
#   1  users tool remove (API): the cookie is refused, and stays refused when
#      the name is re-created; a fresh sign-in of the new account verifies
#   2  the CLI remove revokes too
#   3  the manager's users action (remove) revokes
#   4  rename revokes the OLD name's sessions
#   5  a revocation that cannot be written removes nothing
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use JSON::PP    qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir run_cmd run_child);
use Lazysite::Auth::Session;

my $root   = repo_root();
my $utl    = "$root/tools/lazysite-users.pl";
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sm1070-secret-' x 3;

sub uapi {
    my ( $d, $p ) = @_;
    my $out = run_child( [ $^X, $utl, '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // { _raw => $out };
}

sub site {
    my $d = site_tempdir();
    make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: T\nmanager: enabled\n";
    close $cf;
    open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
    print $sf "$secret\n";
    close $sf;
    run_cmd( $^X, $utl, '--docroot', $d, 'setup-sysop', '--user', 'op', 'op-first-password' );
    uapi( $d, { action => 'add', username => $_, password => "$_-first-password" } ) for qw(alice bob);
    return $d;
}

# What the verifier makes of this cookie: the account, or the reason it is none.
sub who {
    my ( $d, $payload ) = @_;
    no warnings 'once';
    local $Lazysite::Auth::Session::LAZYSITE_DIR = "$d/lazysite";
    local $ENV{HTTP_COOKIE} = 'lazysite_auth=' . $payload . ':' . hmac_sha256_hex( $payload, $secret );
    my ( $id, $why ) = Lazysite::Auth::Session::verify_session_cookie();
    return $id ? $id->{user} : "($why)";
}

sub cookies {
    my $ts = time() - 60;
    return ( sid => "alice:$ts:aaaaaaaaaaaaaaaa:", legacy => "alice:$ts:", bob => "bob:$ts:bbbbbbbbbbbbbbbb:" );
}

sub revoked {
    my ($d) = @_;
    open my $fh, '<', "$d/lazysite/auth/revoked.json" or return {};
    local $/;
    return decode_json(<$fh>);
}

# --- 1. the users tool, and the name re-created --------------------------------
{
    my $d = site();
    my %c = cookies();
    is( who( $d, $c{sid} ), 'alice', 'fixture: alice signs in before anything changes' );
    my $r = uapi( $d, { action => 'remove', username => 'alice' } );
    ok( $r->{ok},                         'remove: ok' ) or diag explain $r;
    ok( revoked($d)->{not_before}{alice}, 'remove: a not_before is written for the account' );
    is( who( $d, $c{bob} ), 'bob', 'remove: another account keeps its session' );

    uapi( $d, { action => 'add', username => 'alice', password => 'a-different-person' } );
    is( who( $d, $c{sid} ), '(revoked)', 're-created: the removed account\'s session stays signed out' );
    is( who( $d, $c{legacy} ), '(revoked)', 're-created: so does its legacy cookie' );
    # Issued after the not_before, as the new account's own sign-in would be: the
    # revocation compares whole seconds, so the clock is not left to decide it.
    is( who( $d, "alice:" . ( time() + 1 ) . ":cccccccccccccccc:" ), 'alice', 're-created: the new account signs in' );
}

# --- 2. the CLI -------------------------------------------------------------------
{
    my $d   = site();
    my $out = run_cmd( $^X, $utl, '--docroot', $d, 'remove', 'alice' );
    like( $out, qr/removed/, 'CLI remove: ok' );
    ok( revoked($d)->{not_before}{alice}, 'CLI remove: the account\'s sessions are revoked' );
}

# --- 3. the manager's users action ------------------------------------------------
{
    my $d    = site();
    my $body = encode_json( { action => 'remove', username => 'alice' } );
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT         => $d,
        REQUEST_METHOD        => 'POST',
        QUERY_STRING          => 'action=users',
        CONTENT_LENGTH        => length($body),
        LAZYSITE_AUTH_TRUSTED => 1,
        HTTP_X_REMOTE_USER    => 'op',
        HTTP_X_CSRF_TOKEN => hmac_sha256_hex( 'csrf:op:' . int( time() / 3600 ), $secret ),
        LAZYSITE_USERS_TOOL => $utl );
    my $out = run_child( [ $^X, $mapi ], stdin => $body )->{out};
    like( $out, qr/"ok":(?:1|true)/, 'manager remove: ok' ) or diag $out;
    ok( revoked($d)->{not_before}{alice}, 'manager remove: the account\'s sessions are revoked' );
}

# --- 4. rename frees the old name -------------------------------------------------
{
    my $d = site();
    my %c = cookies();
    my $r = uapi( $d, { action => 'rename', username => 'alice', to => 'alicia' } );
    ok( $r->{ok},                         'rename: ok' ) or diag explain $r;
    ok( revoked($d)->{not_before}{alice}, 'rename: the old name\'s sessions are revoked' );
    uapi( $d, { action => 'add', username => 'alice', password => 'a-different-person' } );
    is( who( $d, $c{sid} ), '(revoked)', 'rename: a new account under the old name inherits no session' );
}

# --- 5. a revocation that cannot be written removes nothing -----------------------
SKIP: {
    skip 'root ignores file modes', 3 if $> == 0;
    my $d    = site();
    my $lock = "$d/lazysite/auth/revoked.json.lock";
    open my $lf, '>', $lock or die $!;
    close $lf;
    chmod 0000, $lock;
    my $r = uapi( $d, { action => 'remove', username => 'alice' } );
    chmod 0600, $lock;
    ok( !$r->{ok}, 'unwritable revocation: the removal is refused' );
    like( $r->{error} // '', qr/nothing was changed/, 'unwritable revocation: it says nothing changed' );
    open my $uf, '<', "$d/lazysite/auth/users" or die $!;
    ok( ( grep { /^alice:/ } <$uf> ), 'unwritable revocation: the account is still there' );
}

done_testing;
