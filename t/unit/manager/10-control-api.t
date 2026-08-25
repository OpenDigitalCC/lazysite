#!/usr/bin/perl
# SM071 Phase 3: control-API token front-path - token auth, capability
# gating, CSRF exemption, cookie+token rejection, and the account-*
# actor-injection fix (the Phase 2 ancestry-bypass finding).
use strict;
use warnings;
use Test::More;
use File::Temp   qw(tempdir);
use File::Path   qw(make_path);
use JSON::PP     qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);
use Digest::SHA  qw(hmac_sha256_hex);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
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
    # The auth wrapper sets X-Remote-* AND LAZYSITE_AUTH_TRUSTED together; a test that
    # simulates the authenticated path must do the same, or the manager-API trust
    # gate (correctly) strips the header as forged.
    $ENV{LAZYSITE_AUTH_TRUSTED} = 1 if length( $ENV{HTTP_X_REMOTE_USER} // '' );
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
# SM138: a group granting manager access makes the confinement real: a named
# cookie user is a delegated sub-manager (confined to its tree) unless a group
# grants it manage_users. With NO such group, _is_operator treats any user as
# an unrestricted operator (unsecured/dev).
print $cf "layout: base\ntheme: live\nwebdav_enabled: enabled\ncontrol_api_enabled: true\n";
close $cf;
open my $gsf, '>', "$d/lazysite/auth/groups-settings.json" or die $!;
print $gsf '{"admins":{"label":"Admins","ui":1,"manage_users":1}}';
close $gsf;
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!; print $sf "$secret\n"; close $sf;
open my $tj, '>', "$d/lazysite/layouts/base/themes/live/theme.json" or die $!;
print $tj '{"name":"live","layouts":["base"]}'; close $tj;

# partner: token credential + manage_themes
uapi( $d, { action => 'add', username => 'partner', password => 'x' } );
grant_caps( $d, 'partner', 'manage_themes', 'api' ); # SM126: token client holds the api channel cap
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

# --- SM212: an action withheld ON PURPOSE says why ---------------------------
# SM237 separated "exists but you may not call it" from "no such action", which
# are the two an agent must not confuse. This is the third case: an action held
# back deliberately reads exactly like one nobody got round to exposing, and a
# site agent validating 0.10.7 duly recorded the submission deletes as a parity
# gap to be closed. They are not a gap - SM214 keeps them interactive because
# deleting a stored submission is a destructive operation on personal data,
# often on the only copy.
{
    my $pii = mapi( $d,
        REQUEST_METHOD     => 'POST',
        QUERY_STRING       => 'action=form-submission-delete&file=x&id=1',
        HTTP_AUTHORIZATION => basic( 'partner', $tok ) );
    ok( !$pii->{ok}, 'a token client cannot delete a submission' );
    like( $pii->{error}, qr/not available to token/i,
        'and is told it exists but is cookie-only' );
    like( $pii->{error}, qr/personal data/i,
        'AND why - without which "held back" is indistinguishable from '
            . '"not built", which is how it got filed as a defect' );
    like( $pii->{error}, qr/reading submissions IS available/i,
        'and what it CAN do instead, so the refusal is actionable' );

    # The control: an action that is cookie-only for no interesting reason gets
    # the plain sentence, so the explanation means something where it appears.
    my $plain = mapi( $d,
        REQUEST_METHOD     => 'POST',
        QUERY_STRING       => 'action=notices-seen',
        HTTP_AUTHORIZATION => basic( 'partner', $tok ) );
    like( $plain->{error}, qr/not available to token/i,
        'the control is refused the same way' );
    unlike( $plain->{error}, qr/personal data/i,
        'and carries no borrowed explanation' );
}

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

# SM159: nav-read/nav-save are domain-aware - a host selects that domain's
# nav_file override; a domain with no override reads (and edits) the base nav.
{
    open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "alias_hosts: shop.example\n";
    print {$cf} "alias.shop.example.nav_file: sites/shop/nav.conf\n";
    close $cf;
    make_path("$d/sites/shop");
    open my $sn, '>', "$d/sites/shop/nav.conf" or die $!;
    print {$sn} "Shop | /\n";
    close $sn;

    my $base = mapi( $d, QUERY_STRING => 'action=nav-read',
        HTTP_AUTHORIZATION => basic( 'partner', $tok ) );
    is( $base->{items}[0]{label}, 'Home', 'base nav-read returns the base menu' );
    is( $base->{inherited},       0,      'the default host is never marked inherited' );

    my $dom = mapi( $d, QUERY_STRING => 'action=nav-read&host=shop.example',
        HTTP_AUTHORIZATION => basic( 'partner', $tok ) );
    is( $dom->{items}[0]{label}, 'Shop', 'domain nav-read returns that domain override menu' );
    like( $dom->{nav_file}, qr{sites/shop/nav\.conf}, 'domain nav-read resolves the override file' );

    # A domain with NO nav_file override reads the base and is flagged inherited.
    open my $cf2, '>>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf2} "alias.plain.example.content_root: sites/plain\n";
    close $cf2;
    my $inh = mapi( $d, QUERY_STRING => 'action=nav-read&host=plain.example',
        HTTP_AUTHORIZATION => basic( 'partner', $tok ) );
    is( $inh->{inherited}, 1, 'a domain with no nav override is marked inherited (shares the base)' );

    # nav-save with a host writes the domain override, not the base.
    my $save = mapi( $d, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=nav-save',
        HTTP_AUTHORIZATION => basic( 'partner', $tok ),
        body               => encode_json( { host => 'shop.example',
                items => [ { label => 'Cart', url => '/cart', children => [] } ] } ) );
    ok( $save->{ok}, 'domain nav-save ok' ) or diag $save->{error};
    my $shop = do { open my $f, '<', "$d/sites/shop/nav.conf" or die $!; local $/; <$f> };
    like( $shop, qr/Cart \| \/cart/, 'domain nav-save wrote the override file' );
    my $basenav = do { open my $f, '<', "$d/lazysite/nav.conf" or die $!; local $/; <$f> };
    like( $basenav, qr/Home/, 'the base nav is untouched by a domain-scoped save' );
}

# --- SM134 follow-ups: aliases-list is a token action gated by manage_content --
open my $af, '>', "$d/lazysite/aliases.json" or die $!;
print $af '{"/old":"/new","/soon":{"target":"/new","code":302}}';
close $af;
grant_caps( $d, 'partner', 'manage_content' );
my $al = mapi( $d, QUERY_STRING => 'action=aliases-list',
    HTTP_AUTHORIZATION => basic( 'partner', $tok ) );
ok( $al->{ok}, 'aliases-list available to a token client with manage_content' );
is_deeply( $al->{aliases},
    [ { alias => '/old', target => '/new', code => 301 },
        { alias => '/soon', target => '/new', code => 302 } ],
    'aliases-list returns { alias, target, code } rows (old format = 301)' );
my $an = mapi( $d, QUERY_STRING => 'action=aliases-list',
    HTTP_AUTHORIZATION => basic( 'nocap', $tok2 ) );
ok( !$an->{ok} && $an->{error} =~ /capability/i,
    'aliases-list denied to a token without manage_content' );

# --- SM126: the api channel gate + introspection exemption -------------------
# 'nocap' holds no caps (so no api channel). A real action is refused naming the
# api capability, ahead of the per-action check...
my $ag = mapi( $d, QUERY_STRING => 'action=theme-list',
    HTTP_AUTHORIZATION => basic( 'nocap', $tok2 ) );
ok( !$ag->{ok} && $ag->{error} =~ /api/i && $ag->{error} =~ /capabilit/i,
    'token without api: a real action is denied naming the api capability' );

# ...but introspection (whoami, describe-capabilities) stays open.
my $wai = mapi( $d, QUERY_STRING => 'action=whoami',
    HTTP_AUTHORIZATION => basic( 'nocap', $tok2 ) );
ok( $wai->{ok}, 'token without api: whoami still allowed (introspection)' );

my $dcap = mapi( $d, QUERY_STRING => 'action=describe-capabilities',
    HTTP_AUTHORIZATION => basic( 'nocap', $tok2 ) );
ok( $dcap->{ok}, 'token without api: describe-capabilities allowed (introspection)' );
ok( $dcap->{channels}{api}{enforced},            'map: api channel reports enforced' );
ok( exists $dcap->{capabilities}{manage_themes}, 'map lists an action capability' );
ok( @{ $dcap->{tasks} || [] } >= 3,              'map carries task recipes' );
ok( exists $dcap->{holds}{capabilities}{delegate_sub_user_creation},
    'holds carries the full @CAP_KEYS incl. delegate_sub_user_creation (drift fix)' );

# --- SM127: an INTERACTIVE manager account (ui capability + login enabled) is
# refused on the api channel - but introspection stays open (SM126/SM072). -----
uapi( $d, { action => 'add', username => 'mgr', password => 'x' } );
grant_caps( $d, 'mgr', 'ui', 'api', 'manage_content' ); # ui cap + login enabled (default)
my $mtok = uapi( $d, { action => 'token', username => 'mgr' } )->{token};
my $mg   = mapi( $d, QUERY_STRING => 'action=theme-list',
    HTTP_AUTHORIZATION => basic( 'mgr', $mtok ) );
ok( !$mg->{ok} && $mg->{error} =~ /manager|interactive/i,
    'an interactive manager (ui) account is refused on the api channel' );
# ...but whoami (introspection) stays OPEN even for it - the previous ordering
# wrongly refused it (SM126 guarantees introspection is always reachable).
my $mgw = mapi( $d, QUERY_STRING => 'action=whoami',
    HTTP_AUTHORIZATION => basic( 'mgr', $mtok ) );
ok( $mgw->{ok}, 'a manager account: whoami still allowed (introspection open)' );

# --- an AGENT account has the manager `ui` CAPABILITY (from a group) but its
# interactive login is DISABLED (ui:false) - a deliberate agent, as SM127's own
# message advises. Its token must honour its own api-channel capabilities and
# NOT be blocked by the manager-UI gate (the reported 0.8.0 regression). --------
uapi( $d, { action => 'add', username => 'agent', password => 'x' } );
grant_caps( $d, 'agent', 'ui', 'api', 'analytics' );    # manager ui cap + api + analytics
uapi( $d, { action => 'settings-set', username => 'agent', key => 'ui', value => 0 } );
my $atok = uapi( $d, { action => 'token', username => 'agent' } )->{token};
my $aw   = mapi( $d, QUERY_STRING => 'action=whoami',
    HTTP_AUTHORIZATION => basic( 'agent', $atok ) );
ok( $aw->{ok}, 'agent account (login disabled): whoami works' );
ok( !$aw->{capabilities}{ui},
    '...and reports ui:false (interactive login disabled)' );
my $av = mapi( $d, QUERY_STRING => 'action=analyse_visitors',
    HTTP_AUTHORIZATION => basic( 'agent', $atok ) );
unlike( $av->{error} // '', qr/manager|interactive/i,
    'agent account is NOT blocked by the manager-UI gate (its analytics cap governs)' );

# --- CSRF exemption: token POST needs no CSRF token ----------------------
my $pa = mapi( $d, REQUEST_METHOD => 'POST',
    QUERY_STRING       => 'action=theme-activate&path=live',
    HTTP_AUTHORIZATION => basic( 'partner', $tok ) );
unlike( $pa->{error} // '', qr/CSRF/i, 'token POST is exempt from CSRF' );

# --- cookie + token must not be combined ---------------------------------
my $mix = mapi( $d, QUERY_STRING => 'action=artifact-manifest&layout=base&theme=live',
    HTTP_AUTHORIZATION => basic( 'partner', $tok ),
    HTTP_X_REMOTE_USER => 'partner' );
ok( !$mix->{ok} && $mix->{error} =~ /combine/i, 'cookie + token rejected' );

# --- invalid token -------------------------------------------------------
my $bad = mapi( $d, QUERY_STRING => 'action=artifact-manifest&layout=base&theme=live',
    HTTP_AUTHORIZATION => basic( 'partner', 'lzs_' . ( '0' x 64 ) ) );
ok( !$bad->{ok} && $bad->{error} =~ /invalid credentials/i, 'invalid token rejected' );

# --- actor injection: a manager may only manage its own sub-tree ---------
uapi( $d, { action => 'add', username => 'boss', password => 'x' } );
grant_caps( $d, 'boss', 'create_sub_users', 'api' ); # SM126: token client holds the api channel cap
# The audit trail requires its own 'audit' capability (strict gate), separate
# from visitor analytics.
grant_caps( $d, 'boss', 'audit' );
uapi( $d, { action => 'account-create', username => 'child', password => 'x', created_by => 'boss' } );
uapi( $d, { action => 'add', username => 'other', password => 'x' } );

# boss (cookie) disabling its own child: allowed.
my $ok_disable = mapi( $d, REQUEST_METHOD => 'POST',
    HTTP_X_REMOTE_USER => 'boss', HTTP_X_CSRF_TOKEN => csrf('boss'),
    QUERY_STRING => 'action=users',
    body         => encode_json( { action => 'account-disable', username => 'child' } ) );
ok( $ok_disable->{ok}, 'manager may disable an account in its own sub-tree' );

# boss disabling an unrelated account: denied (actor injected -> ancestry).
my $deny = mapi( $d, REQUEST_METHOD => 'POST',
    HTTP_X_REMOTE_USER => 'boss', HTTP_X_CSRF_TOKEN => csrf('boss'),
    QUERY_STRING => 'action=users',
    body         => encode_json( { action => 'account-disable', username => 'other' } ) );
ok( !$deny->{ok}, 'manager may not disable an account outside its sub-tree' );

# --- SM072: whoami introspection of the caller's own grant --------------
grant_caps( $d, 'partner', 'webdav' );
uapi( $d, { action => 'group-add', username => 'partner', group => 'editors' } );
my $who = mapi( $d, QUERY_STRING => 'action=whoami',
    HTTP_AUTHORIZATION => basic( 'partner', $tok ) );
ok( $who->{ok}, 'whoami ok for a token client' );
is( $who->{partner}, 'partner', 'whoami returns the caller id' );
ok( $who->{capabilities}{manage_themes},   'whoami reports manage_themes on' );
ok( !$who->{capabilities}{manage_layouts}, 'whoami reports manage_layouts off' );
ok( ( grep { $_ eq 'editors' } @{ $who->{groups} } ), 'whoami lists the caller groups (editors)' );
ok( ref $who->{plugins} eq 'ARRAY',        'whoami lists plugins' );
ok( exists $who->{layouts}{active_layout}, 'whoami reports the active layout' );
ok( ref $who->{site_capabilities} eq 'ARRAY', 'whoami reports site capabilities from enabled plugins' );

# whoami needs no special capability - nocap can still introspect itself
my $who2 = mapi( $d, QUERY_STRING => 'action=whoami',
    HTTP_AUTHORIZATION => basic( 'nocap', $tok2 ) );
ok( $who2->{ok} && $who2->{partner} eq 'nocap', 'whoami available without a capability' );

# --- SM072: the audit trail records the POST actions above --------------
my $aud = mapi( $d, QUERY_STRING => 'action=audit', HTTP_X_REMOTE_USER => 'boss' );
ok( $aud->{ok} && ref $aud->{entries} eq 'ARRAY', 'audit returns an entries list' );
ok( scalar( @{ $aud->{entries} } ) > 0,           'audit recorded the POST actions' );
ok( ( grep { ( $_->{action} // '' ) =~ /theme-activate|account-disable|users/ } @{ $aud->{entries} } ),
    'audit captured a known POST action with who/what' );
my $auf = mapi( $d, QUERY_STRING => 'action=audit&user=boss', HTTP_X_REMOTE_USER => 'boss' );
ok( !( grep { ( $_->{user} // '' ) ne 'boss' } @{ $auf->{entries} } ), 'per-user filter returns only that user' );

# Strict gate: a token client WITHOUT the audit capability is refused the audit
# trail (nocap holds no capabilities).
my $aud_denied = mapi( $d, QUERY_STRING => 'action=audit',
    HTTP_AUTHORIZATION => basic( 'nocap', $tok2 ) );
ok( !$aud_denied->{ok}, 'audit denied for a client without the audit capability' );

# Separation: analytics and audit are independent. 'partner' has analytics (for
# analyse_visitors below) but NOT audit, so it is refused the audit trail.
grant_caps( $d, 'partner', 'analytics' );
my $aud_no_audit = mapi( $d, QUERY_STRING => 'action=audit',
    HTTP_AUTHORIZATION => basic( 'partner', $tok ) );
ok( !$aud_no_audit->{ok},
    'analytics does NOT grant the audit trail (capabilities are separate)' );

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

# --- SM570: a channel is not an authority ---------------------------------
# The site agent, holding a themes-only grant that also carried webdav for
# theme uploads, read, set and removed content rules. The gate was
# `webdav || manage_content`. A webdav-only grant cannot PUT content, so it
# must not govern content either. A FRESH account: partner has accumulated
# manage_content above, which is exactly the blind spot SM570 is about.
uapi( $d, { action => 'add', username => 'themer', password => 'x' } );
grant_caps( $d, 'themer', 'manage_themes', 'api', 'webdav' );
my $ttok = uapi( $d, { action => 'token', username => 'themer' } )->{token};
ok( $ttok, 'SM570: minted a themes+webdav token' );
for my $a (qw(acl-get acl-remove)) {
    my $r = mapi( $d,
        REQUEST_METHOD     => ( $a eq 'acl-get' ? 'GET' : 'POST' ),
        QUERY_STRING       => "action=$a&path=/index.md",
        HTTP_AUTHORIZATION => basic( 'themer', $ttok ) );
    ok( !$r->{ok} && ( $r->{error} // '' ) =~ /capability/i,
        "SM570: $a refuses a manage_themes+webdav token" )
        or diag explain $r;
}
grant_caps( $d, 'themer', 'manage_content' );
my $now = mapi( $d, QUERY_STRING => 'action=acl-get&path=/index.md',
    HTTP_AUTHORIZATION => basic( 'themer', $ttok ) );
ok( $now->{ok}, 'SM570: and answers once manage_content is granted (control)' )
    or diag explain $now;

done_testing();
