#!/usr/bin/perl
# SM1381: A SITE SESSION THAT IS ONLY STALE IS RENEWED ON THE WAY TO THE PAGE.
#
# A site session the Odoo sign-in minted (SM1160) holds nothing once
# odoo_identity_ttl has passed without Odoo being asked (`odoo-stale`), and only
# the Odoo endpoint's ?csrf=1 renewed it - which a refused protected page never
# loads. So a person idle past the ttl was sent to /login, and /login's
# ?action=session said signed_in false, while their Odoo session was still good.
#
# Now, through the real auth wrapper and processor, the real Odoo endpoint and
# OOM's session transport (a stand-in for Odoo's HTTP):
#
#   * a protected page refuses the stale session to the renewal step, with next
#     (and says so at INFO); the step asks Odoo once and sends the person back to
#     the page, which is served;
#   * if Odoo has ended the session, the step ends the site session and sends the
#     person to /login with next kept;
#   * ?action=session goes through the same step and answers signed_in true once
#     renewed (false, with the marker cleared, when Odoo has ended it);
#   * THE LOOP GUARD: the step sets lzs_renewed for a minute, and a gate that meets
#     a stale session again while it is held sends the person to /login instead;
#   * without the Odoo session cookie (a cross-site request does not carry it)
#     nothing is ended - the person is sent to sign in - and `next` is a same-site
#     path by the sign-in's own rule.
#
# Sabotage: with the renewal branch taken out of check_auth (lazysite-processor/
# auth.pm) the stale page goes straight to /login and the first subtest fails;
# with `renew => ...` taken off the odoo-stale verdict (Auth::Session) every
# subtest that expects the renewal step fails.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json encode_json);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root setup_minimal_site grant_caps env_passthrough processor_path run_child);
use OdooTest   qw(oom_or_skip shop_ready quiet fake_shop odoo_site write_conf);

BEGIN { oom_or_skip() }
use OdooSessionHTTP;
use Lazysite::Odoo             ();
use Lazysite::Odoo::Session    ();
use Lazysite::Odoo::Visitor    ();
use Lazysite::Auth::Session    ();

my $root = repo_root();
my ( $d, $conn_fake ) = shop_ready();
setup_minimal_site($d);
odoo_site($d);
my $LZ = "$d/lazysite";

make_path("$LZ/auth");
grant_caps( $d, 'boss', 'ui' );    # a secured site: the verifier makes nobody from Odoo on an unsecured one
{
    open my $fh, '>', "$LZ/auth/.secret" or die $!;
    print {$fh} 'a' x 64, "\n";
    close $fh;
}

my $PW = 'Quite-a-long-password-for-Jane-1';
my $person_fake = fake_shop( fake => { methods => {
            'res.users.has_group' => sub { return 1 },
} } );
my $http = OdooSessionHTTP->new( fake => $person_fake, people => {
        'jane@example.com' => { password => $PW, uid => 7, name => 'Jane', login => 'jane@example.com' },
} );
$Lazysite::Odoo::Session::HTTP = $http;
$Lazysite::Odoo::TRANSPORT     = $conn_fake;
{
    no warnings 'once';
    $Lazysite::Odoo::Visitor::DOCROOT = $d;
}

write_conf( $d, odoo_url => 'https://odoo.example', odoo_db => 'shopdb', odoo_login => 'site-connection',
    odoo_packs => OdooTest::shop_namespace(), odoo_site_signin => 'on', odoo_group_map => 'base.group_user = staff' );

require "$root/lazysite-odoo.pl";
$Lazysite::Odoo::TRANSPORT = $conn_fake;

my $n_ip = 0;
my $logs = '';

# The Odoo endpoint, in process.
sub request {
    my ( $method, $query, $body, %env ) = @_;
    my $out  = '';
    my $json = defined $body ? encode_json($body) : '';
    {
        local %ENV = (
            PATH => $ENV{PATH}, DOCUMENT_ROOT => $d, REQUEST_METHOD => $method, QUERY_STRING => $query // '',
            REMOTE_ADDR => '198.51.100.' . ( 10 + ++$n_ip ), SCRIPT_NAME => '/cgi-bin/lazysite-odoo.pl',
            CONTENT_LENGTH => length $json, HTTP_HOST => 'localhost',
            map( { ( $_ => $ENV{$_} ) } grep { defined $ENV{$_} } qw(ODOO_OOM_PACK_DIRS ODOO_OOM_SHARE) ),    # OdooTest: no host packs
            %env,
        );
        local *STDOUT;
        open STDOUT, '>', \$out or die $!;
        local *STDIN;
        open STDIN, '<', \$json or die $!;
        my ($log) = quiet( sub { main::main() } );
        $logs .= $log;
    }
    my ( $head, $payload ) = split /\r\n\r\n/, $out, 2;
    my ($status)   = $head =~ /Status:\s*(\d+)/;
    my ($location) = $head =~ /^Location:\s*(\S+)/m;
    my @cookies    = $head =~ /^Set-Cookie:\s*(.*?)\r?$/mg;
    return { status => $status // 0, location => $location // '', cookies => \@cookies,
        body => ( eval { decode_json( $payload // '' ) } || {} ), raw => $out };
}

my %JAR;
sub jar_take {
    my ($cookies) = @_;
    for my $c (@$cookies) {
        next unless $c =~ /\A([^=]+)=([^;]*)/;
        my ( $k, $v ) = ( $1, $2 );
        if ( $c =~ /Max-Age=0/ || $v eq '' ) { delete $JAR{$k} } else { $JAR{$k} = $v }
    }
}
sub jar { my (%skip) = map { $_ => 1 } @_; return join '; ', map { "$_=$JAR{$_}" } grep { !$skip{$_} } sort keys %JAR }

sub sign_in {
    %JAR = ();
    my $t = request( 'GET', 'csrf=1', undef, HTTP_COOKIE => jar() );
    jar_take( $t->{cookies} );
    my $r = request( 'POST', '', { signin => 1, login => 'jane@example.com', password => $PW,
            visitor_token => $t->{body}{visitor_token} }, HTTP_COOKIE => jar() );
    jar_take( $r->{cookies} );
    die "no site session from the sign-in\n" unless $JAR{lazysite_auth};
    return Lazysite::Odoo::Session::sid_from_cookie( 'lzs_odoo_session=' . $JAR{lzs_odoo_session} );
}

sub registry { open my $fh, '<', "$LZ/auth/sessions.jsonl" or return (); my @l = <$fh>; close $fh; return map { decode_json($_) } @l }

# Past odoo_identity_ttl: every Odoo record last checked 1000 s earlier.
sub age {
    my @r = registry();
    open my $fh, '>', "$LZ/auth/sessions.jsonl" or die $!;
    for my $r (@r) { $r->{checked} -= 1000 if $r->{odoo}; print {$fh} JSON::PP->new->canonical->encode($r), "\n" }
    close $fh;
}

sub verdict {
    local $ENV{HTTP_COOKIE} = "lazysite_auth=$JAR{lazysite_auth}";
    local $Lazysite::Auth::Session::LAZYSITE_DIR = $LZ;
    my ( $id, $why ) = Lazysite::Auth::Session::verify_session_cookie();
    return $id ? 'ok' : $why;
}

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh }
spit( "$d/members.md", "---\ntitle: Members\nauth: required\n---\nMEMBERS-AREA\n" );
spit( "$d/login.md",   "---\ntitle: Login\nauth: none\n---\nLOGIN\n" );
{
    open my $cf, '>>', "$LZ/lazysite.conf" or die $!;
    print {$cf} "auth_redirect: /login\n";
    close $cf;
}

# A page, through the REAL auth wrapper and processor (plain CGI, as t/unit/odoo/63).
sub page {
    my ( $uri, $cookie ) = @_;
    local %ENV = (
        env_passthrough(), DOCUMENT_ROOT => $d, REDIRECT_URL => $uri, REQUEST_METHOD => 'GET', QUERY_STRING => '',
        REMOTE_ADDR => '198.51.100.99', HTTPS => '', LAZYSITE_PROCESSOR => processor_path(),
        LAZYSITE_LOG_LEVEL => 'INFO', ( length( $cookie // '' ) ? ( HTTP_COOKIE => $cookie ) : () ),
    );
    my $r   = run_child( [ $^X, "$root/lazysite-auth.pl" ] );
    my $out = $r->{out} // '';
    my ($st)  = $out =~ /^Status:\s*(\d+)/m;
    my ($loc) = $out =~ /^Location:\s*(\S+)/m;
    return { status => $st // 200, location => $loc // '', out => $out, err => $r->{err} // '' };
}

# The auth CGI's ?action=session (SM1322), as /login's check asks it.
sub ask_session {
    my ($cookie) = @_;
    local %ENV = (
        env_passthrough(), DOCUMENT_ROOT => $d, REDIRECT_URL => '/cgi-bin/lazysite-auth.pl', REQUEST_METHOD => 'GET',
        QUERY_STRING => 'action=session', REMOTE_ADDR => '198.51.100.98', HTTP_HOST => 'localhost',
        LAZYSITE_LOG_LEVEL => 'INFO', HTTP_COOKIE => $cookie,
    );
    my $r   = run_child( [ $^X, "$root/lazysite-auth.pl" ] );
    my $out = $r->{out} // '';
    my ( $head, $body ) = split /\r?\n\r?\n/, $out, 2;
    my ($st)  = ( $head // '' ) =~ /^Status:\s*(\d+)/m;
    my ($loc) = ( $head // '' ) =~ /^Location:\s*(\S+)/m;
    return { status => $st // 0, location => $loc // '', body => ( eval { decode_json( $body // '' ) } || {} ),
        out => $out, err => $r->{err} // '' };
}

my $RENEW = '/cgi-bin/lazysite-odoo.pl?renew=1';

# ================================================================================
subtest 'a stale session on a protected page is renewed and returns to the page' => sub {
    sign_in();
    my $site = "lazysite_auth=$JAR{lazysite_auth}; lzs_session=1";
    like( page( '/members', $site )->{out}, qr/MEMBERS-AREA/, 'a fresh session is served the page' );

    age();
    is( verdict(), 'odoo-stale', 'past odoo_identity_ttl the session is stale' );
    my $p = page( '/members', $site );
    is( $p->{status}, 302, 'the protected page refuses it' );
    is( $p->{location}, "$RENEW&next=%2Fmembers", '...to the renewal step, with next' ) or diag $p->{out};
    like( $p->{err}, qr/\[INFO\].*session not accepted - sent to be renewed.*why=odoo-stale/,
        '...and says so at INFO, with the verdict' );

    my $posts = scalar @{ $http->posts };
    my $r = request( 'GET', 'renew=1&next=%2Fmembers', undef, HTTP_COOKIE => jar() );
    is( $r->{status}, 303, 'the step answers with a redirect' ) or diag $r->{raw};
    is( $r->{location}, '/members', '...back to the page' );
    ok( scalar @{ $http->posts } > $posts, 'Odoo was asked' );
    ok( ( grep { /\Alzs_renewed=1;.*Max-Age=60/ } @{ $r->{cookies} } ), 'the loop guard is set, for a minute' );
    jar_take( $r->{cookies} );
    is( verdict(), 'ok', 'the site session is renewed' );
    like( page( '/members', "lazysite_auth=$JAR{lazysite_auth}; lzs_session=1; lzs_renewed=1" )->{out},
        qr/MEMBERS-AREA/, 'and the page is served' );
};

# ================================================================================
subtest 'a session Odoo has ended goes on to /login with next kept' => sub {
    my $sid = sign_in();
    age();
    $http->expire($sid);
    my $p = page( '/members', "lazysite_auth=$JAR{lazysite_auth}; lzs_session=1" );
    is( $p->{location}, "$RENEW&next=%2Fmembers", 'the stale page goes to the renewal step' );
    my $r = request( 'GET', 'renew=1&next=%2Fmembers', undef, HTTP_COOKIE => jar() );
    is( $r->{status},   303,                    'the step redirects' );
    is( $r->{location}, '/login?next=%2Fmembers', '...to the sign-in, next kept' );
    ok( ( grep { /\Alazysite_auth=;.*Max-Age=0/ } @{ $r->{cookies} } ), 'the site session cookie is cleared' );
    is( verdict(), 'revoked', 'and the site session is over' );
};

# ================================================================================
subtest '?action=session renews the same way' => sub {
    my $sid = sign_in();
    age();
    my $cookie = "lazysite_auth=$JAR{lazysite_auth}; lzs_session=1";
    my $a = ask_session($cookie);
    is( $a->{status},   303,                          'a stale session is not answered signed out' );
    is( $a->{location}, "$RENEW&answer=session", '...it goes through the renewal step' ) or diag $a->{out};
    unlike( $a->{out}, qr/^Set-Cookie:\s*lzs_session=;/mi, '...and the marker is left for the step' );
    like( $a->{err}, qr/\[INFO\].*sent to be renewed.*why=odoo-stale/, 'said at INFO' );

    my $r = request( 'GET', 'renew=1&answer=session', undef, HTTP_COOKIE => jar() );
    is( $r->{status}, 200, 'the step answers' );
    is_deeply( $r->{body}, { ok => JSON::PP::true(), signed_in => JSON::PP::true() }, 'signed in, renewed' );
    jar_take( $r->{cookies} );
    is( verdict(), 'ok', 'the session holds again' );
    my $again = ask_session("lazysite_auth=$JAR{lazysite_auth}; lzs_session=1");
    ok( $again->{body}{signed_in}, 'and ?action=session now answers signed in itself' );

    age();
    $http->expire($sid);
    $r = request( 'GET', 'renew=1&answer=session', undef, HTTP_COOKIE => jar() );
    ok( exists $r->{body}{signed_in} && !$r->{body}{signed_in}, 'Odoo ended it: signed out' );
    ok( ( grep { /\Alzs_session=;.*Max-Age=0/ } @{ $r->{cookies} } ), '...and the marker cleared' );
};

# ================================================================================
subtest 'the loop guard: renewal already tried sends the person to sign in' => sub {
    sign_in();
    age();
    my $p = page( '/members', "lazysite_auth=$JAR{lazysite_auth}; lzs_session=1; lzs_renewed=1" );
    is( $p->{status},   302,                    'the stale page is refused' );
    is( $p->{location}, '/login?next=%2Fmembers', '...to the sign-in, not to the step again' );
    like( $p->{err}, qr/\[INFO\].*renewal already tried/, '...and says why at INFO' );
};

# ================================================================================
subtest 'without the Odoo session cookie nothing is ended, and next stays on the site' => sub {
    sign_in();
    age();
    my $posts = scalar @{ $http->posts };
    my $r = request( 'GET', 'renew=1&next=%2Fmembers', undef, HTTP_COOKIE => jar('lzs_odoo_session') );
    is( $r->{location}, '/login?next=%2Fmembers', 'no Odoo session: on to the sign-in' );
    is( scalar @{ $http->posts }, $posts, 'Odoo was not asked' );
    ok( !( grep { /\Alazysite_auth=;/ } @{ $r->{cookies} } ), 'the site session cookie is not cleared' );
    is( verdict(), 'odoo-stale', 'and the session is not ended (still only stale)' );

    $r = request( 'GET', 'renew=1&next=%2F%2Fevil.example%2Fx', undef, HTTP_COOKIE => jar() );
    is( $r->{location}, '/', 'a next that is not a same-site path returns to /' );
    $r = request( 'POST', 'renew=1', {}, HTTP_COOKIE => jar() );
    isnt( $r->{status}, 303, 'the step is a GET only' );
};

diag $logs if $ENV{T135_LOGS};
done_testing();
