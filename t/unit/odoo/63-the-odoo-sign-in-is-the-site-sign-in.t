#!/usr/bin/perl
# SM1160 (inbox L3, release manager's rulings 2026-10-18): ON A SITE THAT OPTS IN, A
# SUCCESSFUL ODOO SIGN-IN THROUGH THE EXTENSION IS THE SITE SIGN-IN.
#
# Through the real Odoo endpoint, OOM's real session transport (a stand-in for Odoo's HTTP),
# OOM's core.has_groups, the real auth wrapper and the real processor:
#
#   * OPT-IN OFF (the default): nothing changes - no site cookie, no registry record, no
#     banner;
#   * ON: the sign-in gives a site session whose identity is `odoo:<login>` and whose groups
#     are the MAPPED lazysite groups the person holds in Odoo (asked as the person); a page
#     restricted to a mapped group is served, one restricted to an unmapped group is refused;
#   * the groups are in the server-side record and NOT in the cookie; a mapping removed, or
#     an xml id Odoo does not know, grants nothing. SM1217: from OOM 0.37 core.has_groups
#     answers an unknown id 0, like one not held, so it can no longer be named; status says
#     so instead of carrying an empty list (t/unit/odoo/90 holds the report and check);
#   * A MAPPING TO A GROUP THAT CARRIES ANY CAPABILITY IS REFUSED BY NAME - at save and again
#     at load - so manager rights are never given by an Odoo group;
#   * two-factor: the site session is minted only after the code;
#   * signing out ends both (Odoo's session destroyed, the site sid revoked, cookies cleared);
#   * an Odoo session that has ended ends the site session at the next request that learns of
#     it, and a site session whose record is older than odoo_identity_ttl grants nothing until
#     ?csrf=1 asks Odoo once and renews it;
#   * a forged, mis-signed, record-less, or other-site cookie is no identity, and a forged
#     header is not believed;
#   * the page's "Signed in as" banner is in the default layout.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json encode_json);
use File::Path qw(make_path);
use File::Copy qw(copy);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root setup_minimal_site site_tempdir grant_caps env_passthrough processor_path run_child);
use OdooTest   qw(oom_or_skip shop_ready bind quiet fake_shop odoo_site write_conf);

BEGIN { oom_or_skip() }
use OdooSessionHTTP;
use Lazysite::Odoo               ();
use Lazysite::Odoo::Session      ();
use Lazysite::Odoo::Visitor      ();
use Lazysite::Odoo::SiteSignin   ();
use Lazysite::Auth::Session      ();
use Lazysite::Manager::Plugins   ();

my $root = repo_root();
my ( $d, $conn_fake ) = shop_ready();
setup_minimal_site($d);
odoo_site($d);
my $LZ = "$d/lazysite";

# A SECURED site: one group grants manager access (the verifier refuses to make an Odoo
# person anyone on an unsecured one). And a group that carries a capability, which the map
# below tries to give.
make_path("$LZ/auth");
grant_caps( $d, 'boss', 'ui' );
grant_caps( $d, 'opsuser', 'api' );
{
    open my $fh, '>', "$LZ/auth/.secret" or die $!;
    print {$fh} 'a' x 64, "\n";
    close $fh;
}

my $PW = 'Quite-a-long-password-for-Jane-1';

# What each person holds in Odoo, by uid. SM1217: OOM 0.37 dropped core.has_groups'
# ir.model.data check_object_reference call, so this fake no longer answers it: Odoo is
# asked has_group and nothing else, and an id it has no group for answers 0.
my %HELD = ( 7 => { 'sales.group_wholesale' => 1, 'base.group_user' => 1, 'sales.group_admin' => 1 } );
my @ASKED;    # [ uid, xmlid ] for every has_group Odoo answered
my $person_fake = fake_shop( fake => { methods => {
            'res.users.has_group' => sub {
                my ( $fk, $args ) = @_;
                my $id = ref $args->[0] eq 'ARRAY' ? $args->[1] : $args->[0];
                push @ASKED, [ $fk->{caller_uid}, $id ];
                return $HELD{ $fk->{caller_uid} }{$id} ? 1 : 0;
            },
} } );
my $http = OdooSessionHTTP->new( fake => $person_fake, people => {
        'jane@example.com' => { password => $PW, uid => 7, name => 'Jane', login => 'jane@example.com' },
        'kim@example.com'  => { password => $PW, uid => 8, name => 'Kim',  login => 'kim@example.com' },
        'otp@example.com'  => { password => $PW, uid => 9, name => 'Otto', login => 'otp@example.com', totp => '482915' },
} );
$HELD{8} = {};
$HELD{9} = { 'sales.group_wholesale' => 1 };
$Lazysite::Odoo::Session::HTTP = $http;
$Lazysite::Odoo::TRANSPORT     = $conn_fake;
{
    no warnings 'once';
    $Lazysite::Odoo::Visitor::DOCROOT = $d;
}
bind( $d, id => 'mine', operation => 'shop.products', credential => 'session', modes => 'authenticated' );

my %BASE = (
    odoo_url => 'https://odoo.example', odoo_db => 'shopdb', odoo_login => 'site-connection',
    odoo_allow_writes => 'true', odoo_packs => OdooTest::shop_namespace(),
);
my $MAP = 'sales.group_wholesale = wholesale, base.group_user = staff, sales.group_admin = role-opsuser, no.such_group = ghost';
sub conf_on  { write_conf( $d, %BASE, odoo_site_signin => 'on', odoo_group_map => $MAP, @_ ) }
sub conf_off { write_conf( $d, %BASE, odoo_group_map => $MAP ) }

require "$root/lazysite-odoo.pl";
$Lazysite::Odoo::TRANSPORT = $conn_fake;

my $SCRIPT = '/cgi-bin/lazysite-odoo.pl';
my $n_ip   = 0;
my $all_logs = '';

sub request {
    my ( $method, $query, $body, %env ) = @_;
    my $out  = '';
    my $json = defined $body ? encode_json($body) : '';
    {
        local %ENV = (
            PATH => $ENV{PATH}, DOCUMENT_ROOT => $d, REQUEST_METHOD => $method, QUERY_STRING => $query // '',
            REMOTE_ADDR => '198.51.100.' . ( 10 + ++$n_ip ), SCRIPT_NAME => $SCRIPT, CONTENT_LENGTH => length $json,
            HTTP_HOST => 'localhost', %env,
        );
        local *STDOUT;
        open STDOUT, '>', \$out or die $!;
        local *STDIN;
        open STDIN, '<', \$json or die $!;
        my ($log) = quiet( sub { main::main() } );
        $all_logs .= $log;
    }
    my ( $head, $payload ) = split /\r\n\r\n/, $out, 2;
    my ($status) = $head =~ /Status:\s*(\d+)/;
    my @cookies = $head =~ /^Set-Cookie:\s*(.*?)\r?$/mg;
    return ( $status // 0, \@cookies, ( eval { decode_json( $payload // '' ) } || {} ), $out );
}

sub cookie_value {
    my ( $cookies, $name ) = @_;
    my $v;
    for my $c (@$cookies) { $v = $1 if $c =~ /\A\Q$name\E=([^;]*)/ }    # the last one set wins
    return $v;
}

sub cookie_line { my ( $c, $n ) = @_; return ( grep { /\A\Q$n\E=/ } @$c )[-1] }

# A browser: the cookies it holds, as a Cookie header
my %JAR;
sub jar_take {
    my ($cookies) = @_;
    for my $c (@$cookies) {
        next unless $c =~ /\A([^=]+)=([^;]*)/;
        my ( $k, $v ) = ( $1, $2 );
        if ( $c =~ /Max-Age=0/ || $v eq '' ) { delete $JAR{$k} } else { $JAR{$k} = $v }
    }
}
sub jar { return join '; ', map { "$_=$JAR{$_}" } sort keys %JAR }

sub fresh_tokens {
    my ( undef, $ck, $tok ) = request( 'GET', 'csrf=1', undef, HTTP_COOKIE => jar() );
    jar_take($ck);
    return $tok;
}

my $VT;
sub sign_in {
    my (%o) = @_;
    $VT = fresh_tokens()->{visitor_token};
    my ( $st, $ck, $j ) = request( 'POST', '', { signin => 1, login => $o{login} // 'jane@example.com',
            password => $PW, visitor_token => $VT }, HTTP_COOKIE => jar() );
    jar_take($ck);
    return ( $st, $ck, $j );
}

sub sign_out {
    my $vt = fresh_tokens()->{visitor_token};
    my ( $st, $ck, $j ) = request( 'POST', '', { signout => 1, visitor_token => $vt }, HTTP_COOKIE => jar() );
    jar_take($ck);
    return ( $st, $ck, $j );
}

# The wrapper's own verification, on a cookie
sub verify {
    my ($cookie_header) = @_;
    local $ENV{HTTP_COOKIE} = $cookie_header;
    local $Lazysite::Auth::Session::LAZYSITE_DIR = $LZ;
    return Lazysite::Auth::Session::verify_session_cookie();
}
sub site_cookie_header { return "lazysite_auth=" . ( $JAR{lazysite_auth} // '' ) }

sub registry { open my $fh, '<', "$LZ/auth/sessions.jsonl" or return (); my @l = <$fh>; close $fh; return map { decode_json($_) } @l }

# --- the page, through the REAL wrapper and processor ------------------------------
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh }
spit( "$d/wholesale.md", "---\ntitle: Wholesale\nauth: required\nauth_groups:\n  - wholesale\n---\nWHOLESALE-PRICES\n" );
spit( "$d/vip.md",       "---\ntitle: VIP\nauth: required\nauth_groups:\n  - vip\n---\nVIP-ONLY\n" );
spit( "$d/members.md",   "---\ntitle: Members\nauth: required\n---\nMEMBERS-AREA\n" );
spit( "$d/login.md",     "---\ntitle: Login\nauth: none\n---\nLOGIN\n" );
{
    open my $cf, '>>', "$LZ/lazysite.conf" or die $!;
    print {$cf} "auth_redirect: /login\n";
    close $cf;
}

sub page {
    my ( $uri, %o ) = @_;
    local %ENV = (
        env_passthrough(), DOCUMENT_ROOT => $d, REDIRECT_URL => $uri, REQUEST_METHOD => 'GET', QUERY_STRING => '',
        REMOTE_ADDR => '198.51.100.99', HTTPS => '', LAZYSITE_PROCESSOR => processor_path(),
        ( length( $o{cookie} // '' ) ? ( HTTP_COOKIE => $o{cookie} ) : () ), %{ $o{env} || {} },
    );
    my $out = run_child( [ $^X, "$root/lazysite-auth.pl" ] )->{out};
    my ($st) = ( $out // '' ) =~ /^Status:\s*(\d+)/m;
    return ( $st // 200, $out // '' );
}

# ================================================================================
subtest 'opt-in OFF: nothing changes' => sub {
    conf_off();
    %JAR = ();
    my ( $st, $ck, $j ) = sign_in();
    is( $st, 200, 'the Odoo sign-in works as it did' );
    ok( cookie_value( $ck, 'lzs_odoo_session' ), 'with its Odoo session cookie' );
    ok( !cookie_value( $ck, 'lazysite_auth' ), 'and NO site session cookie' );
    ok( !cookie_value( $ck, 'lzs_session' ),   'nor the display marker' );
    ok( !-e "$LZ/auth/sessions.jsonl", 'and no session record was made' );
    is( scalar @ASKED, 0, 'Odoo was not asked about groups' );
    my $t = fresh_tokens();
    is( $t->{identity}{name}, 'Jane', '?csrf=1 names the person from the identity cookie, as before' );
    sign_out();
    my ( $ps, $page ) = page('/');
    unlike( $page, qr/data-ls-odoo-banner/, 'the page carries no Signed-in-as banner' );
    %JAR = ();
};

# ================================================================================
subtest 'the map is checked: a capability-carrying group is refused by name, at load and at save' => sub {
    conf_on();
    my ( $map, $refused ) = Lazysite::Odoo::SiteSignin::group_map($LZ);
    is_deeply( $map, { 'sales.group_wholesale' => 'wholesale', 'base.group_user' => 'staff', 'no.such_group' => 'ghost' },
        'only the groups that carry nothing are in the map' );
    is( scalar @$refused, 1, 'one entry refused' );
    is( $refused->[0]{xmlid}, 'sales.group_admin', 'by its Odoo group' );
    is( $refused->[0]{group}, 'role-opsuser',      'and the site group it named' );
    like( $refused->[0]{why}, qr/carries capabilities.*never granted/s, 'and why' );
    my $v = Lazysite::Odoo::SiteSignin::validate_group_map( $MAP, $LZ );
    like( $v, qr/sales\.group_admin = role-opsuser.*refused/, 'the save-time check names it' );
    is( Lazysite::Odoo::SiteSignin::validate_group_map( 'base.group_user = staff', $LZ ), '', 'and passes a clean map' );

    # a group that nests a capability-carrying one is refused too
    my $gsf = "$LZ/auth/groups-settings.json";
    open my $in, '<', $gsf or die $!;
    my $gs = decode_json( do { local $/; <$in> } );
    close $in;
    $gs->{wrapper} = { label => 'wrapper', includes => ['role-opsuser'] };
    $gs->{'role-opsuser'}{label} = 'x';
    open my $out, '>', $gsf or die $!;
    print {$out} encode_json($gs);
    close $out;
    my $gr = "$LZ/auth/groups";
    my ( $m2, $r2 ) = Lazysite::Odoo::SiteSignin::parse_map( 'base.group_user = role-opsuser', $LZ );
    ok( !exists $m2->{'base.group_user'}, 'the capability group directly: refused' );
    ok( scalar @$r2, 'and named' );

    # the plugin-save path refuses it with the operator on the form
    my $parent = site_tempdir();
    my $sd     = "$parent/public_html";
    make_path( "$sd/lazysite/auth", "$parent/plugins" );
    copy( "$root/plugins/odoo.pl", "$parent/plugins/odoo.pl" ) or die $!;
    chmod 0755, "$parent/plugins/odoo.pl";
    copy( $gsf, "$sd/lazysite/auth/groups-settings.json" ) or die $!;
    local $ENV{PERL5LIB} = "$root/lib" . ( $ENV{PERL5LIB} ? ":$ENV{PERL5LIB}" : '' );
    local $Lazysite::Manager::Plugins::DOCROOT = $sd;
    my $res = Lazysite::Manager::Plugins::action_plugin_save( undef, 'plugins/odoo.pl',
        { odoo_group_map => 'sales.group_admin = role-opsuser' } );
    is( $res->{ok}, 0, 'saving a mapping to a capability group fails' );
    is( $res->{field}, 'odoo_group_map', 'naming the field' );
    like( $res->{error}, qr/sales\.group_admin = role-opsuser/, 'and the entry' );
    ok( !-e "$sd/lazysite/odoo.conf" || ( do { open my $c, '<', "$sd/lazysite/odoo.conf"; local $/; <$c> } // '' ) !~ /group_admin/,
        'and it was not written' );
    $res = Lazysite::Manager::Plugins::action_plugin_save( undef, 'plugins/odoo.pl',
        { odoo_group_map => 'base.group_user = staff' } );
    ok( $res->{ok}, 'a clean map saves' );
};

# ================================================================================
subtest 'opt-in ON: the Odoo sign-in is the site sign-in, with the mapped groups' => sub {
    conf_on();
    %JAR = ();
    @ASKED = ();
    my ( $st, $ck, $j ) = sign_in();
    is( $st, 200, 'signed in' ) or diag explain $j;
    my $line = cookie_line( $ck, 'lazysite_auth' );
    ok( $line, 'a site session cookie' );
    like( $line, qr/; HttpOnly/,       'HttpOnly' );
    like( $line, qr/; SameSite=Lax/,   'SameSite=Lax' );
    like( $line, qr{; Path=/(?:;|\z)}, 'for the whole site' );
    ok( cookie_value( $ck, 'lzs_session' ), 'and the display marker, as a login sets it' );

    my ( $id, $why ) = verify( site_cookie_header() );
    ok( $id, 'it verifies' ) or diag $why;
    is( $id->{user}, 'odoo:jane@example.com', 'as the identity odoo:<login>' );
    is( $id->{groups}, 'staff,wholesale', 'with the MAPPED groups Jane holds (and not the refused or unknown ones)' );
    is( $id->{name}, 'Jane', 'and her name' );
    my %asked = map { ( $_->[1] => $_->[0] ) } @ASKED;
    is_deeply( [ sort keys %asked ], [qw(base.group_user no.such_group sales.group_wholesale)],
        'Odoo was asked about exactly the mapped ids (the refused one is never asked)' );
    is_deeply( [ values %asked ], [ (7) x 3 ], 'as the person (uid 7), through her own session' );
    ok( !-e "$LZ/odoo/unknown-groups.json", 'and no list of unknown ids is written: Odoo answered the unknown one 0' );

    # the cookie carries no group
    my $raw = $JAR{lazysite_auth};
    ( my $payload = $raw ) =~ s/:[0-9a-f]{64}\z//;
    $payload =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
    my @f = split /:/, $payload, 4;
    is( $f[0], 'odoo=jane@example.com', 'the user field is odoo=<login>' );
    is( $f[3], '', 'the groups field is empty: the cookie carries no group' );
    unlike( $raw, qr/wholesale|staff/, 'neither name is anywhere in the cookie' );
    my ($rec) = grep { $_->{odoo} } registry();
    is_deeply( $rec->{groups}, [qw(staff wholesale)], 'the groups are in the server-side record' );
    is( $rec->{user}, 'odoo:jane@example.com', 'under the identity' );

    # pages, through the wrapper and the real processor
    my $c = site_cookie_header();
    my ( $s1, $p1 ) = page( '/wholesale', cookie => $c );
    like( $p1, qr/WHOLESALE-PRICES/, 'a page restricted to a mapped group is served' );
    my ( $s2, $p2 ) = page( '/vip', cookie => $c );
    unlike( $p2, qr/VIP-ONLY/, 'a page restricted to an unmapped group is not' );
    like( $s2, qr/\A(?:403|302)\z/, 'it is refused (403 or the sign-in redirect)' );
    my ( $s3, $p3 ) = page( '/members', cookie => $c );
    like( $p3, qr/MEMBERS-AREA/, 'a page for any signed-in person is served' );
    my ( $s4, $p4 ) = page('/members');
    unlike( $p4, qr/MEMBERS-AREA/, 'and not without the cookie' );

    # a person who holds none of the mapped groups
    my %SAVE = %JAR;
    %JAR = ();
    sign_in( login => 'kim@example.com' );
    my ( $kid ) = verify( site_cookie_header() );
    is( $kid->{user}, 'odoo:kim@example.com', 'Kim is signed in' );
    is( $kid->{groups}, '', 'holding no mapped group' );
    my ( undef, $pk ) = page( '/wholesale', cookie => site_cookie_header() );
    unlike( $pk, qr/WHOLESALE-PRICES/, 'and is refused the wholesale page' );
    %JAR = %SAVE;

    # the CURRENT map is applied at every request: taking a mapping away takes the group away at once
    conf_on( odoo_group_map => 'base.group_user = staff' );
    is( ( verify( site_cookie_header() ) )[0]{groups}, 'staff', 'a mapping removed stops granting its group before any refresh' );
    conf_on();

    # the audit actor is the identity
    open my $af, '<', "$LZ/logs/audit.log" or die "audit: $!";
    my $audit = do { local $/; <$af> };
    close $af;
    like( $audit, qr/\| odoo:jane\@example\.com \| login \|[^\n]*\| ok \| odoo/, 'the audit trail names odoo:<login> as the actor' );

    # status names the refused entry, and says an unknown id cannot be named (SM1217)
    my $stt = Lazysite::Odoo::action_odoo_status();
    is( $stt->{site_signin}{enabled}, 1, 'status: on' );
    is( $stt->{site_signin}{refused}[0]{xmlid}, 'sales.group_admin', 'status names the refused mapping' );
    ok( !exists $stt->{site_signin}{unknown}, 'status carries no list of unknown ids, which would read as "none"' );
    is( $stt->{site_signin}{unknown_named}, 0, 'it says unknown ids are not named' );
    like( $stt->{site_signin}{unknown_note} // '', qr/does not know .* not named/, 'and why, in words' );
};

# ================================================================================
subtest 'the banner: "Signed in as <name>" with a sign-out, on every page of such a site' => sub {
    conf_on();
    my ( undef, $page ) = page('/login');
    like( $page, qr/data-ls-odoo-banner/, 'the default layout renders odoo_signin_banner' );
    like( $page, qr/Signed in as <strong data-ls-odoo-name>/, 'with the name slot' );
    like( $page, qr/<a href="#" data-ls-odoo-signout>Sign out<\/a>/, 'and a sign-out link' );
    like( $page, qr{/assets/lazysite-odoo\.js}, 'the helper that fills it is on the page' );
    unlike( $page, qr/data-ls-auth-out/, 'in place of the account sign-out, which would leave the Odoo session' );
    conf_off();
    my ( undef, $off ) = page('/login');
    unlike( $off, qr/data-ls-odoo-banner/, 'a site without the opt-in has none' );
    like( $off, qr/data-ls-auth-out/, 'and keeps the account links' );
    conf_on();
};

# ================================================================================
subtest 'two-factor: the site session is minted only after the code' => sub {
    conf_on();
    %JAR = ();
    my $vt = fresh_tokens()->{visitor_token};
    my ( $st, $ck, $j ) = request( 'POST', '', { signin => 1, login => 'otp@example.com', password => $PW, visitor_token => $vt },
        HTTP_COOKIE => jar() );
    jar_take($ck);
    is( $j->{second_factor}, 'totp', 'the password asks for the code' );
    ok( !cookie_value( $ck, 'lazysite_auth' ), 'and no site session exists yet' );
    ok( !( grep { $_->{user} eq 'odoo:otp\@example.com' } registry() ), 'nor a record' );
    ( $st, $ck, $j ) = request( 'POST', '', { signin_code => 1, code => '730164', visitor_token => $vt }, HTTP_COOKIE => jar() );
    jar_take($ck);
    isnt( $st, 200, 'a wrong code is refused' );
    ok( !cookie_value( $ck, 'lazysite_auth' ), 'and no site session exists' );
    ( $st, $ck, $j ) = request( 'POST', '', { signin_code => 1, code => '482915', visitor_token => $vt }, HTTP_COOKIE => jar() );
    jar_take($ck);
    is( $st, 200, 'the right code signs in' ) or diag explain $j;
    my ($id) = verify( site_cookie_header() );
    is( $id->{user}, 'odoo:otp@example.com', 'and now there is a site session' );
    is( $id->{groups}, 'wholesale', 'with the groups Odoo says Otto holds' );
    %JAR = ();
};

# ================================================================================
subtest 'sign-out ends both sessions' => sub {
    conf_on();
    %JAR = ();
    sign_in();
    my $site_cookie = site_cookie_header();
    my ($id) = verify($site_cookie);
    ok( $id, 'signed in at the site' );
    my $odoo_sid = Lazysite::Odoo::Session::sid_from_cookie( 'lzs_odoo_session=' . $JAR{lzs_odoo_session} );
    ok( $http->sessions->{$odoo_sid}, 'and in Odoo' );
    my $destroys = scalar grep { $_->{path} eq '/web/session/destroy' } @{ $http->posts };
    my ( $st, $ck ) = sign_out();
    is( $st, 200, 'signed out' );
    ok( !$http->sessions->{$odoo_sid}, 'the Odoo session was ended through OOM' );
    is( scalar( grep { $_->{path} eq '/web/session/destroy' } @{ $http->posts } ), $destroys + 1, 'by one destroy call' );
    like( cookie_line( $ck, 'lazysite_auth' ), qr/Max-Age=0/, 'the site session cookie is cleared' );
    like( cookie_line( $ck, 'lzs_session' ),   qr/Max-Age=0/, 'and the marker' );
    my ( $after, $why ) = verify($site_cookie);
    ok( !$after, 'a copy of the old site cookie is dead' );
    is( $why, 'revoked', 'revoked, by the mechanism the wrapper uses' );
    my ( undef, $p ) = page( '/members', cookie => $site_cookie );
    unlike( $p, qr/MEMBERS-AREA/, 'and opens nothing' );
    open my $af, '<', "$LZ/logs/audit.log" or die;
    like( do { local $/; <$af> }, qr/\| odoo:jane\@example\.com \| logout \|/, 'the sign-out is audited under the identity' );
};

# ================================================================================
subtest 'an ended Odoo session ends the site session; an old record asks Odoo once' => sub {
    conf_on();
    %JAR = ();
    sign_in();
    my $site_cookie = site_cookie_header();
    my $odoo_sid    = Lazysite::Odoo::Session::sid_from_cookie( 'lzs_odoo_session=' . $JAR{lzs_odoo_session} );

    # age the record past odoo_identity_ttl
    my $age = sub {
        my ($by) = @_;
        my @r = registry();
        open my $fh, '>', "$LZ/auth/sessions.jsonl" or die $!;
        for my $r (@r) { $r->{checked} -= $by if $r->{odoo}; print {$fh} JSON::PP->new->canonical->encode($r), "\n" }
        close $fh;
    };
    $age->(1000);
    my ( $id, $why ) = verify($site_cookie);
    ok( !$id, 'a record last checked more than odoo_identity_ttl ago grants nothing' );
    is( $why, 'odoo-stale', 'said as stale' );

    # a quiet page: ?csrf=1 within the ttl makes no Odoo call
    my $posts = scalar @{ $http->posts };

    # the stale session asks Odoo once, and is renewed with the groups as they now are
    delete $HELD{7}{'sales.group_wholesale'};
    @ASKED = ();
    my ( undef, $ck, $tok ) = request( 'GET', 'csrf=1', undef, HTTP_COOKIE => jar() );
    jar_take($ck);
    is( $tok->{identity}{name}, 'Jane', '?csrf=1 still names her' );
    ok( scalar @{ $http->posts } > $posts, 'Odoo was asked' );
    ($id) = verify( site_cookie_header() );
    ok( $id, 'the site session is renewed' );
    is( $id->{groups}, 'staff', 'with the groups Odoo now says (wholesale gone)' );
    is( scalar( grep { $_->{odoo} && $_->{sid} eq $id->{sid} } registry() ), 2, 'as a newer line of the same record' );
    $posts = scalar @{ $http->posts };
    @ASKED = ();
    request( 'GET', 'csrf=1', undef, HTTP_COOKIE => jar() );
    is( scalar @ASKED, 0, 'a second ?csrf=1 inside the ttl asks Odoo nothing' );
    is( scalar @{ $http->posts }, $posts, 'no call at all' );
    $HELD{7}{'sales.group_wholesale'} = 1;

    # Odoo forgets the session; the next ?csrf=1 after the ttl learns it
    $age->(1000);
    $http->expire($odoo_sid);
    ( undef, $ck, $tok ) = request( 'GET', 'csrf=1', undef, HTTP_COOKIE => jar() );
    like( cookie_line( $ck, 'lazysite_auth' ) // '', qr/Max-Age=0/, 'the site cookie is cleared' );
    ok( !$tok->{identity}, 'no identity is shown' );
    jar_take($ck);
    ( $id, $why ) = verify($site_cookie);
    ok( !$id, 'and the old cookie no longer verifies' );
    is( $why, 'revoked', 'its sid revoked' );

    # and an Odoo call that answers session-ended ends it, without waiting for the ttl
    %JAR = ();
    sign_in();
    $site_cookie = site_cookie_header();
    $odoo_sid = Lazysite::Odoo::Session::sid_from_cookie( 'lzs_odoo_session=' . $JAR{lzs_odoo_session} );
    ok( ( verify($site_cookie) )[0], 'a new site session' );
    $http->expire($odoo_sid);
    my ( $gs, $gck, $gj ) = request( 'GET', 'binding=mine', undef, HTTP_COOKIE => jar() );
    is( $gs, 401, 'a session binding answers sign-in-required' );
    like( cookie_line( $gck, 'lazysite_auth' ) // '', qr/Max-Age=0/, 'and clears the site session cookie' );
    ( $id, $why ) = verify($site_cookie);
    ok( !$id, 'the site session is over' );

    # an Odoo session with no site session behind it is ended too
    %JAR = ();
    sign_in();
    $odoo_sid = Lazysite::Odoo::Session::sid_from_cookie( 'lzs_odoo_session=' . $JAR{lzs_odoo_session} );
    delete $JAR{lazysite_auth};    # signed out at the wrapper's own logout, say
    request( 'GET', 'csrf=1', undef, HTTP_COOKIE => jar() );
    ok( !$http->sessions->{$odoo_sid}, 'the Odoo session is ended with it' );
};

# ================================================================================
subtest 'a forged, mis-signed, record-less or foreign credential is no identity' => sub {
    conf_on();
    %JAR = ();
    sign_in();
    my $good = $JAR{lazysite_auth};
    ok( ( verify("lazysite_auth=$good") )[0], 'the real cookie verifies (control)' );

    # the signature
    ( my $bad = $good ) =~ s/.\z/@{[ substr($good, -1) eq '0' ? '1' : '0' ]}/;
    is( ( verify("lazysite_auth=$bad") )[1], 'signature', 'a cookie with a bad signature' );
    ( my $other = $good ) =~ s/jane/mary/;
    ok( !( verify("lazysite_auth=$other") )[0], 'a cookie whose user was changed' );

    # signed with the real secret but naming a session with no record
    my $secret = 'a' x 64;
    my $mk = sub {
        my ($payload) = @_;
        my $sig = hmac_sha256_hex( $payload, $secret );
        ( my $e = $payload ) =~ s/([^a-zA-Z0-9_.~:-])/sprintf( '%%%02X', ord $1 )/ge;
        return "lazysite_auth=$e:$sig";
    };
    my $now = time;
    is( ( verify( $mk->("odoo=jane\@example.com:$now:0123456789abcdef:wholesale") ) )[1], 'no-record',
        'a validly signed cookie naming a session with no record (and a group in the payload)' );
    my ($rec) = grep { $_->{odoo} } registry();
    is( ( verify( $mk->("odoo=mary\@example.com:$now:$rec->{sid}:") ) )[1], 'no-record',
        "a valid signature on another person's name over this session's sid: the record names someone else" );
    ok( !( verify( $mk->("odoo:jane\@example.com:$now:$rec->{sid}:wholesale") ) )[0],
        'a payload that spells the identity with a colon is read as a local one, and is no identity' );
    ok( !( verify( $mk->("odoo=%00x:$now:$rec->{sid}:") ) )[0], 'a login with a control byte is refused' );

    # a login with a colon in it round-trips, and cannot be a local name
    local $Lazysite::Auth::Session::LAZYSITE_DIR = $LZ;
    my ( $c, $ts, $sid ) = Lazysite::Auth::Session::mint_odoo_session( login => 'we:ird%name@x.org', name => 'W', groups => ['staff'] );
    ok( $c, 'a login holding ":" and "%" can be carried' );
    my ($wid) = verify("lazysite_auth=$c");
    is( $wid->{user}, 'odoo:we:ird%name@x.org', 'and comes back whole' );
    unlike( $c, qr/(?:^|:)odoo:/, 'the payload never has the identity spelled with a colon' );

    # off means off; unsecured means no identity
    conf_off();
    is( ( verify("lazysite_auth=$good") )[1], 'odoo-off', 'turning the opt-in off ends the sessions' );
    conf_on();
    ok( ( verify("lazysite_auth=$good") )[0], 'and on again restores the (unrevoked) session' );
    rename "$LZ/auth/groups-settings.json", "$LZ/auth/groups-settings.json.away" or die $!;
    is( ( verify("lazysite_auth=$good") )[1], 'odoo-unsecured', 'on an unsecured site (no group grants manager access) it is no identity' );
    rename "$LZ/auth/groups-settings.json.away", "$LZ/auth/groups-settings.json" or die $!;

    # a forged header is not believed: nobody here is behind a trusted proxy
    my ( undef, $ph ) = page( '/wholesale', env => { HTTP_X_REMOTE_USER => 'odoo:jane@example.com', HTTP_X_REMOTE_GROUPS => 'wholesale' } );
    unlike( $ph, qr/WHOLESALE-PRICES/, 'a client-sent X-Remote-User: odoo:... opens nothing' );

    # a stolen cookie after the identity cookie and ttl: asks nothing of Odoo on its own
    # (covered in the previous subtest); and an Odoo-minted person holds no capability
    my ( $st, undef, $j ) = request( 'GET', 'csrf=1', undef, HTTP_COOKIE => "lazysite_auth=$good; " . jar() );
    ok( !defined $j->{token} || length $j->{token}, 'the endpoint issues a session token for the identity (CSRF is keyed on it)' );
    require Lazysite::Auth::Settings;
    {
        no warnings 'once';
        local $Lazysite::Auth::Settings::AUTH_DIR = "$LZ/auth";
        my $caps = Lazysite::Auth::Settings::caps_for('odoo:jane@example.com');
        is_deeply( [ grep { $caps->{$_} } keys %$caps ], [], 'odoo:<login> holds no capability in the account store' );
    }
};

done_testing;
