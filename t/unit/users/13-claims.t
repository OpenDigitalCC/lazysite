#!/usr/bin/perl
# SM072 batch 1: the claim-token primitive - mint, redeem, single-use,
# expiry, revoke (Reset credential), disabled, and ancestry.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps);

my $root   = repo_root();
my $script = "$root/tools/lazysite-users.pl";

sub fresh_docroot {
    my $d = tempdir( CLEANUP => 1 );
    mkdir "$d/lazysite";
    mkdir "$d/lazysite/auth";
    return $d;
}

sub cli {
    my ( $docroot, @args ) = @_;
    my ( $wtr, $rdr ); my $err = gensym;
    my $pid = open3( $wtr, $rdr, $err, $^X, $script, '--docroot', $docroot, @args );
    close $wtr;
    my $out = do { local $/; <$rdr> }; my $eout = do { local $/; <$err> };
    waitpid $pid, 0;
    return { out => $out // '', err => $eout // '', code => $? >> 8 };
}

sub api {
    my ( $docroot, $payload ) = @_;
    my ( $cout, $cin );
    my $pid = open2( $cout, $cin, $^X, $script, '--api', '--docroot', $docroot );
    print $cin encode_json($payload); close $cin;
    my $out = do { local $/; <$cout> }; close $cout;
    waitpid $pid, 0;
    return eval { decode_json($out) } // { _raw => $out };
}

sub settings { api( $_[0], { action => 'settings-get',     username => $_[1] } )->{settings} }
sub verify   { api( $_[0], { action => 'verify-credential', username => $_[1], secret => $_[2] } ) }
sub setfile  { "$_[0]/lazysite/auth/user-settings.json" }

# --- set-password claim: mint -> redeem -> password works -------------
{
    my $d = fresh_docroot();
    cli( $d, 'add', 'alice', '' );          # no password yet; ui on by default
    my $c = api( $d, { action => 'claim-create', username => 'alice' } );
    ok( $c->{ok}, 'claim-create ok' );
    is( $c->{purpose}, 'set-password', 'interactive account => set-password claim' );
    ok( settings( $d, 'alice' )->{claim_pending}, 'claim shows pending' );

    my $r = api( $d, { action => 'claim-redeem', username => 'alice',
                       claim => $c->{claim}, password => 's3cret' } );
    ok( $r->{ok}, 'claim-redeem ok' );
    ok( verify( $d, 'alice', 's3cret' )->{ok}, 'the password the user set works' );
    ok( !settings( $d, 'alice' )->{claim_pending}, 'claim cleared after redeem' );

    my $again = api( $d, { action => 'claim-redeem', username => 'alice',
                           claim => $c->{claim}, password => 'other' } );
    ok( !$again->{ok}, 'claim is single-use' );
    like( $again->{error}, qr/Invalid or expired/, 'generic error on reuse' );
}

# --- mint-token claim for a machine (ui off) account ------------------
{
    my $d = fresh_docroot();
    cli( $d, 'add', 'keeper', 'pw' );        # keep a ui account so bot isn't "the last"
    cli( $d, 'add', 'bot', '' );
    cli( $d, 'set', 'bot', 'ui', 'off' );
    my $c = api( $d, { action => 'claim-create', username => 'bot' } );
    is( $c->{purpose}, 'mint-token', 'machine account => mint-token claim' );
    my $r = api( $d, { action => 'claim-redeem', username => 'bot', claim => $c->{claim} } );
    ok( $r->{ok} && $r->{token}, 'redeem yields a token' );
    like( $r->{token}, qr/^lzs_/, 'token has the lzs_ prefix' );
    ok( verify( $d, 'bot', $r->{token} )->{ok}, 'the minted token authenticates' );
}

# --- wrong token and expired claim are both generic failures ----------
{
    my $d = fresh_docroot();
    cli( $d, 'add', 'carol', '' );
    my $c = api( $d, { action => 'claim-create', username => 'carol' } );

    my $bad = api( $d, { action => 'claim-redeem', username => 'carol',
                         claim => 'lzc_deadbeef', password => 'x' } );
    ok( !$bad->{ok}, 'wrong claim rejected' );
    like( $bad->{error}, qr/Invalid or expired/, 'generic' );

    open my $in, '<', setfile($d); my $j = decode_json( do { local $/; <$in> } ); close $in;
    $j->{carol}{claim_expires_at} = time() - 1;            # force expiry
    open my $out, '>', setfile($d); print $out encode_json($j); close $out;
    my $exp = api( $d, { action => 'claim-redeem', username => 'carol',
                         claim => $c->{claim}, password => 'x' } );
    ok( !$exp->{ok}, 'expired claim rejected' );
    like( $exp->{error}, qr/Invalid or expired/, 'generic' );
}

# --- Reset credential: revoke the old secret + issue a fresh claim ----
{
    my $d = fresh_docroot();
    cli( $d, 'add', 'dave', '' );
    my $c1 = api( $d, { action => 'claim-create', username => 'dave' } );
    api( $d, { action => 'claim-redeem', username => 'dave', claim => $c1->{claim}, password => 'first' } );
    ok( verify( $d, 'dave', 'first' )->{ok}, 'first password works' );

    my $reset = api( $d, { action => 'claim-create', username => 'dave', revoke => 1 } );
    ok( $reset->{ok}, 'reset issues a new claim' );
    ok( !verify( $d, 'dave', 'first' )->{ok}, 'old credential revoked' );
    ok( settings( $d, 'dave' )->{claim_pending}, 'fresh claim pending' );

    api( $d, { action => 'claim-redeem', username => 'dave', claim => $reset->{claim}, password => 'second' } );
    ok( verify( $d, 'dave', 'second' )->{ok}, 'user sets a new password via the reset claim' );
    ok( !verify( $d, 'dave', 'first' )->{ok}, 'the old password stays dead' );
}

# --- a disabled account cannot be provisioned -------------------------
{
    my $d = fresh_docroot();
    cli( $d, 'add', 'eve', '' );
    api( $d, { action => 'account-disable', username => 'eve' } );
    my $c = api( $d, { action => 'claim-create', username => 'eve' } );
    ok( !$c->{ok}, 'claim-create refused for a disabled account' );
}

# --- claim-create respects ancestry (operator-triggered, scoped) ------
{
    my $d = fresh_docroot();
    cli( $d, 'add', 'mgr', 'pw' );
    grant_caps( $d, 'mgr', 'create_sub_users' );
    api( $d, { action => 'account-create', username => 'kid', password => 'pw',
               created_by => 'mgr', actor => 'mgr' } );
    cli( $d, 'add', 'stranger', 'pw' );

    my $ok = api( $d, { action => 'claim-create', username => 'kid', actor => 'mgr' } );
    ok( $ok->{ok}, 'a manager can mint a claim for its descendant' );
    my $no = api( $d, { action => 'claim-create', username => 'kid', actor => 'stranger' } );
    ok( !$no->{ok}, 'an unrelated actor cannot' );
    like( $no->{error}, qr/[Nn]ot authorised/, 'ancestry enforced' );
}

# --- account expiry: time-boxed access --------------------------------
{
    my $d = fresh_docroot();
    cli( $d, 'add', 'temp', 'pw' );
    ok( verify( $d, 'temp', 'pw' )->{ok}, 'valid before any expiry' );

    cli( $d, 'set', 'temp', 'expires_at', '2000-01-01' );      # past
    ok( !verify( $d, 'temp', 'pw' )->{ok}, 'expired account fails auth' );

    cli( $d, 'set', 'temp', 'expires_at', '2999-12-31' );      # future
    ok( verify( $d, 'temp', 'pw' )->{ok}, 'future expiry still authenticates' );
    ok( settings( $d, 'temp' )->{expires_at} > time(), 'expires_at stored as a future epoch' );

    cli( $d, 'set', 'temp', 'expires_at', '' );                # clear
    ok( !defined settings( $d, 'temp' )->{expires_at}, 'empty value clears the expiry' );
    ok( verify( $d, 'temp', 'pw' )->{ok}, 'valid again once expiry cleared' );
}

# --- rename moves credentials, settings, groups, and provenance --------
{
    my $d = fresh_docroot();
    cli( $d, 'add', 'alice', 'pw' );
    grant_caps( $d, 'alice', 'create_sub_users' );
    cli( $d, 'group-add', 'alice', 'editors' );
    api( $d, { action => 'account-create', username => 'kid', password => 'pw',
               created_by => 'alice', actor => 'alice' } );

    my $r = api( $d, { action => 'rename', username => 'alice', to => 'alice2' } );
    ok( $r->{ok}, 'rename ok' );
    ok(  verify( $d, 'alice2', 'pw' )->{ok}, 'credential moved to the new name' );
    ok( !verify( $d, 'alice',  'pw' )->{ok}, 'old name no longer authenticates' );
    ok( settings( $d, 'alice2' )->{create_sub_users}, 'settings moved with the account' );
    is( settings( $d, 'kid' )->{created_by}, 'alice2', 'sub-user provenance follows the rename' );

    my @ed = @{ api( $d, { action => 'groups' } )->{groups}{editors} || [] };
    ok(  ( grep { $_ eq 'alice2' } @ed ), 'group membership renamed' );
    ok( !( grep { $_ eq 'alice'  } @ed ), 'old name gone from the group' );

    cli( $d, 'add', 'bob', 'pw' );
    my $clash = api( $d, { action => 'rename', username => 'alice2', to => 'bob' } );
    ok( !$clash->{ok}, 'rename to an existing name is rejected' );
}

done_testing();
