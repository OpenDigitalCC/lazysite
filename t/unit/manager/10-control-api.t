#!/usr/bin/perl
# SM071 Phase 3: control-API token front-path - token auth, capability
# gating, CSRF exemption, cookie+token rejection, and the account-*
# actor-injection fix (the Phase 2 ancestry-bypass finding).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use Digest::SHA qw(hmac_sha256_hex);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root  = repo_root();
my $utool = "$root/tools/lazysite-users.pl";
my $mapi  = "$root/lazysite-manager-api.pl";
my $secret = 'sekret' x 6;

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p); close $i;
    my $out = do { local $/; <$o> }; close $o; waitpid $pid, 0;
    return eval { decode_json($out) } // { _raw => $out };
}

# Run the manager API with the given CGI env and optional body; return the
# decoded JSON response.
sub mapi {
    my ( $d, %o ) = @_;
    my $body = delete $o{body};
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{REQUEST_METHOD} = $o{REQUEST_METHOD} || 'GET';
    $ENV{CONTENT_LENGTH} = defined $body ? length($body) : 0;
    delete $ENV{HTTP_X_REMOTE_USER};
    for ( keys %o ) { $ENV{$_} = $o{$_} if defined $o{$_} }
    my ( $w, $r ); my $e = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    print $w ( defined $body ? $body : '' ); close $w;
    my $out = do { local $/; <$r> }; my $err = do { local $/; <$e> };
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out, _err => $err };
}

sub basic { 'Basic ' . encode_base64( "$_[0]:$_[1]", '' ) }
sub csrf  { hmac_sha256_hex( "csrf:$_[0]:" . int( time() / 3600 ), $secret ) }

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
make_path("$d/lazysite/layouts/base/themes/live");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "layout: base\ntheme: live\n";
close $cf;
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!; print $sf "$secret\n"; close $sf;
open my $tj, '>', "$d/lazysite/layouts/base/themes/live/theme.json" or die $!;
print $tj '{"name":"live","layouts":["base"]}'; close $tj;

# partner: token credential + manage_themes
uapi( $d, { action => 'add', username => 'partner', password => 'x' } );
uapi( $d, { action => 'settings-set', username => 'partner', key => 'manage_themes', value => 'on' } );
my $tok = uapi( $d, { action => 'token', username => 'partner' } )->{token};
ok( $tok && $tok =~ /^lzs_/, 'minted partner token' );

# nocap: token credential, no capability
uapi( $d, { action => 'add', username => 'nocap', password => 'x' } );
my $tok2 = uapi( $d, { action => 'token', username => 'nocap' } )->{token};

# --- token auth + capability: artifact-manifest --------------------------
my $m = mapi( $d, QUERY_STRING => 'action=artifact-manifest&layout=base&theme=live',
    HTTP_AUTHORIZATION => basic( 'partner', $tok ) );
ok( $m->{ok}, 'token artifact-manifest ok with manage_themes' );
ok( exists $m->{manifest}{'theme.json'}, 'manifest lists theme.json with hash' );

# --- capability gating ---------------------------------------------------
my $ng = mapi( $d, QUERY_STRING => 'action=artifact-manifest&layout=base&theme=live',
    HTTP_AUTHORIZATION => basic( 'nocap', $tok2 ) );
ok( !$ng->{ok} && $ng->{error} =~ /capability/i, 'no capability -> denied' );

# --- non-allowlisted action via token ------------------------------------
my $na = mapi( $d, QUERY_STRING => 'action=read&path=/index.md',
    HTTP_AUTHORIZATION => basic( 'partner', $tok ) );
ok( !$na->{ok} && $na->{error} =~ /not available to token/i,
    'non-allowlisted action refused for token clients' );

# --- CSRF exemption: token POST needs no CSRF token ----------------------
my $pa = mapi( $d, REQUEST_METHOD => 'POST',
    QUERY_STRING => 'action=theme-activate&path=live',
    HTTP_AUTHORIZATION => basic( 'partner', $tok ) );
unlike( $pa->{error} // '', qr/CSRF/i, 'token POST is exempt from CSRF' );

# --- cookie + token must not be combined ---------------------------------
my $mix = mapi( $d, QUERY_STRING => 'action=artifact-manifest&layout=base&theme=live',
    HTTP_AUTHORIZATION => basic( 'partner', $tok ),
    HTTP_X_REMOTE_USER => 'partner' );
ok( !$mix->{ok} && $mix->{error} =~ /combine/i, 'cookie + token rejected' );

# --- invalid token -------------------------------------------------------
my $bad = mapi( $d, QUERY_STRING => 'action=artifact-manifest&layout=base&theme=live',
    HTTP_AUTHORIZATION => basic( 'partner', 'lzs_' . ('0' x 64) ) );
ok( !$bad->{ok} && $bad->{error} =~ /invalid credentials/i, 'invalid token rejected' );

# --- actor injection: a manager may only manage its own sub-tree ---------
uapi( $d, { action => 'add', username => 'boss', password => 'x' } );
uapi( $d, { action => 'settings-set', username => 'boss', key => 'create_sub_users', value => 'on' } );
uapi( $d, { action => 'account-create', username => 'child', password => 'x', created_by => 'boss' } );
uapi( $d, { action => 'add', username => 'other', password => 'x' } );

# boss (cookie) disabling its own child: allowed.
my $ok_disable = mapi( $d, REQUEST_METHOD => 'POST',
    HTTP_X_REMOTE_USER => 'boss', HTTP_X_CSRF_TOKEN => csrf('boss'),
    QUERY_STRING => 'action=users',
    body => encode_json({ action => 'account-disable', username => 'child' }) );
ok( $ok_disable->{ok}, 'manager may disable an account in its own sub-tree' );

# boss disabling an unrelated account: denied (actor injected -> ancestry).
my $deny = mapi( $d, REQUEST_METHOD => 'POST',
    HTTP_X_REMOTE_USER => 'boss', HTTP_X_CSRF_TOKEN => csrf('boss'),
    QUERY_STRING => 'action=users',
    body => encode_json({ action => 'account-disable', username => 'other' }) );
ok( !$deny->{ok}, 'manager may not disable an account outside its sub-tree' );

done_testing();
