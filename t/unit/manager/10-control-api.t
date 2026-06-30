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
use TestHelper qw(repo_root grant_caps);

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
# manager_groups makes the confinement real: a named cookie user is a
# delegated sub-manager (confined to its tree) unless it is in this group.
# Without it, _is_operator treats any user as an unrestricted operator.
print $cf "layout: base\ntheme: live\nmanager_groups: admins\nwebdav_enabled: enabled\n";
close $cf;
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!; print $sf "$secret\n"; close $sf;
open my $tj, '>', "$d/lazysite/layouts/base/themes/live/theme.json" or die $!;
print $tj '{"name":"live","layouts":["base"]}'; close $tj;

# partner: token credential + manage_themes
uapi( $d, { action => 'add', username => 'partner', password => 'x' } );
grant_caps( $d, 'partner', 'manage_themes' );
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

# --- SM105: nav-read/nav-save are token actions gated by manage_nav ----------
# manage_nav inherits manage_content which inherits webdav, so a webdav partner
# can manage the nav over the control API (no MCP / raw-WebDAV needed).
open my $nv, '>', "$d/lazysite/nav.conf" or die $!; print $nv "Home | /\n"; close $nv;
grant_caps( $d, 'partner', 'webdav', 'manage_nav' );
my $nr = mapi( $d, QUERY_STRING => 'action=nav-read',
    HTTP_AUTHORIZATION => basic( 'partner', $tok ) );
ok( $nr->{ok}, 'nav-read available to a token client with manage_nav' );
my $nn = mapi( $d, QUERY_STRING => 'action=nav-read',
    HTTP_AUTHORIZATION => basic( 'nocap', $tok2 ) );
ok( !$nn->{ok} && $nn->{error} =~ /capability/i,
    'nav-read denied to a token without manage_nav' );

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
grant_caps( $d, 'boss', 'create_sub_users' );
# The audit trail now requires the analytics capability (strict gate).
grant_caps( $d, 'boss', 'analytics' );
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

# --- SM072: whoami introspection of the caller's own grant --------------
grant_caps( $d, 'partner', 'webdav' );
uapi( $d, { action => 'group-add', username => 'partner', group => 'editors' } );
my $who = mapi( $d, QUERY_STRING => 'action=whoami',
    HTTP_AUTHORIZATION => basic( 'partner', $tok ) );
ok( $who->{ok}, 'whoami ok for a token client' );
is( $who->{partner}, 'partner', 'whoami returns the caller id' );
ok( $who->{capabilities}{manage_themes},  'whoami reports manage_themes on' );
ok( !$who->{capabilities}{manage_layouts}, 'whoami reports manage_layouts off' );
ok( ( grep { $_ eq 'editors' } @{ $who->{groups} } ), 'whoami lists the caller groups (editors)' );
ok( ref $who->{plugins} eq 'ARRAY', 'whoami lists plugins' );
ok( exists $who->{layouts}{active_layout}, 'whoami reports the active layout' );
ok( ref $who->{site_capabilities} eq 'ARRAY', 'whoami reports site capabilities from enabled plugins' );

# whoami needs no special capability - nocap can still introspect itself
my $who2 = mapi( $d, QUERY_STRING => 'action=whoami',
    HTTP_AUTHORIZATION => basic( 'nocap', $tok2 ) );
ok( $who2->{ok} && $who2->{partner} eq 'nocap', 'whoami available without a capability' );

# --- SM072: the audit trail records the POST actions above --------------
my $aud = mapi( $d, QUERY_STRING => 'action=audit', HTTP_X_REMOTE_USER => 'boss' );
ok( $aud->{ok} && ref $aud->{entries} eq 'ARRAY', 'audit returns an entries list' );
ok( scalar( @{ $aud->{entries} } ) > 0, 'audit recorded the POST actions' );
ok( ( grep { ( $_->{action} // '' ) =~ /theme-activate|account-disable|users/ } @{ $aud->{entries} } ),
    'audit captured a known POST action with who/what' );
my $auf = mapi( $d, QUERY_STRING => 'action=audit&user=boss', HTTP_X_REMOTE_USER => 'boss' );
ok( !( grep { ( $_->{user} // '' ) ne 'boss' } @{ $auf->{entries} } ), 'per-user filter returns only that user' );

# Strict gate: a token client WITHOUT the analytics capability is refused the
# audit trail (nocap holds no capabilities).
my $aud_denied = mapi( $d, QUERY_STRING => 'action=audit',
    HTTP_AUTHORIZATION => basic( 'nocap', $tok2 ) );
ok( !$aud_denied->{ok}, 'audit denied for a client without the analytics capability' );

# SM095: analytics (visitor stats) is available over the CONTROL API too, gated on
# the analytics capability - so an API-channel agent gets it, not only MCP.
my $av_denied = mapi( $d, QUERY_STRING => 'action=analyse_visitors',
    HTTP_AUTHORIZATION => basic( 'nocap', $tok2 ) );
ok( !$av_denied->{ok}, 'analyse_visitors denied without analytics' );

grant_caps( $d, 'partner', 'analytics' );
my $alog = "$d/access.log";
open my $lg, '>', $alog or die $!;
print {$lg} '1.2.3.4 - - [01/Jan/2026:00:00:00 +0000] "GET /x HTTP/1.1" 200 1 "-" "curl/8"' . "\n";
close $lg;
my $av = mapi( $d, QUERY_STRING => 'action=analyse_visitors',
    HTTP_AUTHORIZATION => basic( 'partner', $tok ), LAZYSITE_ACCESS_LOG => $alog );
ok( $av->{ok}, 'analyse_visitors works for a client with analytics' ) or diag explain $av;
ok( exists $av->{traffic_classes}, 'returns the sanitised stats export shape' );

done_testing();
