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

# ---------------------------------------------------------------------------
# SM212: operator-set, ceiling-capped token_ttl + sliding renewal.
# ---------------------------------------------------------------------------
my $read_exp = sub {
    open my $fh, '<', $settings_file->($doc) or die $!;
    return decode_json( do { local $/; <$fh> } )->{deploy}{token_expires_at};
};

# The floor and ceiling gate an operator's set.
ok( !api( $doc, { action => 'settings-set', username => 'deploy',
        key => 'token_ttl', value => '60d' } )->{ok},
    'SM212: token_ttl above the 30d ceiling is rejected' );
ok( !api( $doc, { action => 'settings-set', username => 'deploy',
        key => 'token_ttl', value => '5m' } )->{ok},
    'SM212: token_ttl below the 1h floor is rejected' );

# A valid 30d TTL: a fresh exchange lasts ~30d, not the 24h default.
ok( api( $doc, { action => 'settings-set', username => 'deploy',
        key => 'token_ttl', value => '30d' } )->{ok},
    'SM212: a 30d token_ttl is accepted' );
my $pk30 = api( $doc, { action => 'pairing-key', username => 'deploy' } );
my $ex30 = api( $doc, { action => 'token-exchange',
    username => 'deploy', pairing_key => $pk30->{pairing_key} } );
ok( $ex30->{ok} && $ex30->{expires_at} - time() > 29 * 86400,
    'SM212: a token issued under a 30d TTL lasts ~30d, not 24h' )
    or diag 'life=' . ( ( $ex30->{expires_at} // 0 ) - time() );
my $tok30 = $ex30->{token};

# The resolver clamps a hand-edited / legacy token_ttl beyond the ceiling.
mutate_settings( $doc, 'deploy', sub { $_[0]->{token_ttl} = 999 * 86400 } );
my $pkC = api( $doc, { action => 'pairing-key', username => 'deploy' } );
my $exC = api( $doc, { action => 'token-exchange',
    username => 'deploy', pairing_key => $pkC->{pairing_key} } );
ok( $exC->{ok} && $exC->{expires_at} - time() <= 30 * 86400 + 60,
    'SM212: the resolver clamps a >30d token_ttl to the ceiling at issue' );

# Sliding renewal: a token part-way through its window, when USED, has its expiry
# slid forward to ~now + token_ttl (an in-use token never lapses). Restore the
# valid 30d ttl and re-exchange first (the clamp test left a huge raw value).
api( $doc, { action => 'settings-set', username => 'deploy', key => 'token_ttl', value => '30d' } );
my $pkS = api( $doc, { action => 'pairing-key', username => 'deploy' } );
my $tokS = api( $doc, { action => 'token-exchange',
    username => 'deploy', pairing_key => $pkS->{pairing_key} } )->{token};
mutate_settings( $doc, 'deploy', sub {
    $_[0]->{token_expires_at} = time() + 3600;    # only 1h left
    delete $_[0]->{cred_used_at};                 # force touch_credential to write
} );
is( run_dav( $doc, 'OPTIONS', '/', HTTP_AUTHORIZATION => basic( 'deploy', $tokS ) )->{code},
    200, 'SM212: an in-window token authenticates' );
ok( $read_exp->() > time() + 29 * 86400,
    'SM212: using the token slid its expiry forward to ~30d out' )
    or diag 'after-now=' . ( $read_exp->() - time() );

# Default TTL (token_ttl cleared): sliding does NOT apply - a used token keeps its
# original expiry (the 24h-from-issuance posture is unchanged by default).
api( $doc, { action => 'settings-set', username => 'deploy', key => 'token_ttl', value => '' } );
my $pkD = api( $doc, { action => 'pairing-key', username => 'deploy' } );
my $tokD = api( $doc, { action => 'token-exchange',
    username => 'deploy', pairing_key => $pkD->{pairing_key} } )->{token};
mutate_settings( $doc, 'deploy', sub {
    $_[0]->{token_expires_at} = time() + 3600;
    delete $_[0]->{cred_used_at};
} );
run_dav( $doc, 'OPTIONS', '/', HTTP_AUTHORIZATION => basic( 'deploy', $tokD ) );
ok( $read_exp->() < time() + 2 * 3600,
    'SM212: a default token (no token_ttl) does NOT slide on use' )
    or diag 'afterD-now=' . ( $read_exp->() - time() );

done_testing();
