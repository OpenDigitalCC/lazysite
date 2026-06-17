#!/usr/bin/perl
# SM071 Phase 2: token lifecycle (model A) - pairing key -> exchange ->
# short-lived access token -> rotation, with expiry enforced over DAV.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use IPC::Open2;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root run_dav setup_dav_site);

my $script = repo_root() . "/tools/lazysite-users.pl";

sub api {
    my ( $docroot, $payload ) = @_;
    my ( $co, $ci );
    my $pid = open2( $co, $ci, $^X, $script, '--api', '--docroot', $docroot );
    print $ci encode_json($payload);
    close $ci;
    my $out = do { local $/; <$co> };
    close $co;
    waitpid $pid, 0;
    return eval { decode_json($out) } // { _raw => $out };
}

sub basic { 'Basic ' . encode_base64( "$_[0]:$_[1]", '' ) }

my $settings_file = sub { "$_[0]/lazysite/auth/user-settings.json" };
sub mutate_settings {
    my ( $docroot, $user, $code ) = @_;
    my $f = $settings_file->($docroot);
    open my $fh, '<', $f or die "read settings: $!";
    my $data = decode_json( do { local $/; <$fh> } );
    close $fh;
    $code->( $data->{$user} );
    open my $w, '>', $f or die "write settings: $!";
    print $w encode_json($data);
    close $w;
}

my $s   = setup_dav_site();          # user 'deploy', webdav on
my $doc = $s->{docroot};

# --- pairing key -> exchange -> working access token ------------------
my $pk = api( $doc, { action => 'pairing-key', username => 'deploy' } );
ok( $pk->{ok} && $pk->{pairing_key} =~ /^lzp_/, 'pairing key minted' );

my $ex = api( $doc, { action => 'token-exchange',
    username => 'deploy', pairing_key => $pk->{pairing_key} } );
ok( $ex->{ok} && $ex->{token} =~ /^lzs_/, 'pairing key exchanged for access token' );
my $token = $ex->{token};

my $r = run_dav( $doc, 'OPTIONS', '/', HTTP_AUTHORIZATION => basic( 'deploy', $token ) );
is( $r->{code}, 200, 'fresh access token authenticates over DAV' );

# --- pairing key is single-use ----------------------------------------
my $reuse = api( $doc, { action => 'token-exchange',
    username => 'deploy', pairing_key => $pk->{pairing_key} } );
ok( !$reuse->{ok}, 'pairing key cannot be exchanged twice' );

# --- expired access token is rejected ---------------------------------
mutate_settings( $doc, 'deploy', sub { $_[0]->{token_expires_at} = time() - 10 } );
my $exp = run_dav( $doc, 'OPTIONS', '/', HTTP_AUTHORIZATION => basic( 'deploy', $token ) );
is( $exp->{code}, 401, 'expired access token rejected (401)' );
like( $exp->{body}, qr/expired/i, 'rejection mentions expiry' );

# --- rotation issues a new token; the old one stops working -----------
my $rot = api( $doc, { action => 'token-rotate', username => 'deploy' } );
ok( $rot->{ok} && $rot->{token} =~ /^lzs_/, 'token rotated' );
my $new = $rot->{token};

my $old = run_dav( $doc, 'OPTIONS', '/', HTTP_AUTHORIZATION => basic( 'deploy', $token ) );
isnt( $old->{code}, 200, 'old token no longer authenticates after rotation' );

my $cur = run_dav( $doc, 'OPTIONS', '/', HTTP_AUTHORIZATION => basic( 'deploy', $new ) );
is( $cur->{code}, 200, 'rotated token authenticates and expiry is reset' );

# --- expired pairing key cannot be exchanged --------------------------
my $pk2 = api( $doc, { action => 'pairing-key', username => 'deploy' } );
mutate_settings( $doc, 'deploy', sub { $_[0]->{pairing_key_expires_at} = time() - 10 } );
my $stale = api( $doc, { action => 'token-exchange',
    username => 'deploy', pairing_key => $pk2->{pairing_key} } );
ok( !$stale->{ok}, 'expired pairing key rejected' );

done_testing();
