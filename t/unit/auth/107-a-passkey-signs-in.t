#!/usr/bin/perl
# SM1352: a passkey signs a person in, through the real lazysite-auth.pl.
#
#   - a challenge comes from ?action=passkey-challenge; the signed answer is a form
#     POST to ?action=passkey-login, and a good one mints an ordinary local session
#     (the session cookie, a registry row, the audit's login ok with "passkey")
#   - verified against fixture keys made with CryptX in this test: ES256, RS256 and
#     Ed25519
#   - refused, with no session: a wrong signature, a replayed challenge, a wrong
#     origin, another site's RP ID, an answer to a challenge never issued, and a
#     signature counter that does not move forward
#   - without CryptX the challenge says what is missing
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir run_child);

plan skip_all => 'CryptX is not installed' unless eval { require Crypt::PK::ECC; 1 };
require PasskeyFixture;

my $root   = repo_root();
my $auth   = "$root/lazysite-auth.pl";
my $utl    = "$root/tools/lazysite-users.pl";
my $HOST   = 'site.example';
my $ORIGIN = "https://$HOST";

sub uapi {
    my ( $d, $p ) = @_;
    my $out = run_child( [ $^X, $utl, '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // { _raw => $out };
}

sub cgi {
    my ( $d, $action, $body, %o ) = @_;
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT  => $d,
        REQUEST_METHOD => 'POST',
        QUERY_STRING   => "action=$action",
        CONTENT_LENGTH => length $body,
        REMOTE_ADDR    => '192.0.2.40',
        HTTP_HOST      => $HOST,
        HTTPS          => 'on',
        LAZYSITE_USERS_TOOL => $utl,
        %{ $o{env} || {} },
    );
    return run_child( [ $^X, $auth ], stdin => $body, stderr => 'inherit' )->{out} // '';
}

sub challenge {
    my ( $d, %o ) = @_;
    my $out = cgi( $d, 'passkey-challenge', 'purpose=signin', %o );
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

sub signin {
    my ( $d, %f ) = @_;
    return cgi( $d, 'passkey-login', PasskeyFixture::form( %f, next => '/' ) );
}

sub session_cookie { my ($out) = @_; return $out =~ /^Set-Cookie: lazysite_auth=([^;]+)/m ? $1 : '' }
sub location       { my ($out) = @_; return $out =~ /^Location: (\S+)/m ? $1 : '' }

my $d = site_tempdir();
make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
{
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: T\nauth_redirect: /login\n";
    close $cf;
}
uapi( $d, { action => 'add', username => 'alice', password => 'alice-first-password' } );
uapi( $d, { action => 'add', username => 'bob',   password => 'bob-first-password-x' } );

my %K = map { $_ => PasskeyFixture::key($_) } ( -7, -257, -8 );
for my $alg ( -7, -257 ) {
    my $r = uapi( $d, { action => 'passkey-add', username => 'alice', passkey => PasskeyFixture::stored( $K{$alg} ) } );
    ok( $r->{ok}, "fixture: alice holds an alg $alg passkey" ) or diag explain $r;
}
ok( uapi( $d, { action => 'passkey-add', username => 'bob', passkey => PasskeyFixture::stored( $K{-8} ) } )->{ok},
    'fixture: bob holds an Ed25519 passkey' );

# --- a good answer signs in ---------------------------------------------------------------
my $c = challenge($d);
ok( $c->{ok} && length( $c->{challenge} // '' ), 'a challenge is issued' ) or diag explain $c;
is( $c->{rp_id}, $HOST, 'for this host as the RP ID' );
my %good = PasskeyFixture::asserted( $K{-7}, challenge => $c->{challenge}, origin => $ORIGIN, rp => $HOST, count => 1 );
my $out  = signin( $d, %good );
like( $out, qr/^Status: 302/m, 'ES256: the sign-in answers as a password sign-in does' );
like( session_cookie($out), qr/\Aalice(?:%3A|:)/, 'and sets the ordinary session cookie, for alice' );
is( location($out), '/', 'and lands where it was asked to' );
{
    open my $fh, '<', "$d/lazysite/auth/sessions.jsonl" or die $!;
    my @rows = grep { ( decode_json($_)->{user} // '' ) eq 'alice' } <$fh>;
    close $fh;
    is( scalar @rows, 1, 'the session is in the registry, like any local session' );
}
{
    open my $fh, '<', "$d/lazysite/logs/audit.log" or die "no audit log: $!";
    my $log = do { local $/; <$fh> };
    close $fh;
    like( $log, qr/\|\s*alice\s*\|\s*login\s*\|.*\|\s*ok\s*\|.*passkey/, 'the audit records a login by passkey' );
}

# --- the same answer again: the challenge is spent ------------------------------------------
my $again = signin( $d, %good );
is( session_cookie($again), '', 'a replayed answer gets no session' );
like( location($again), qr/error=passkey\b/, 'and is told the passkey was not accepted' );

# --- a wrong signature ---------------------------------------------------------------------
$c = challenge($d);
my %wrong = PasskeyFixture::asserted( $K{-7}, challenge => $c->{challenge}, origin => $ORIGIN, rp => $HOST,
    count => 2, signer => PasskeyFixture::key(-7) );
is( session_cookie( signin( $d, %wrong ) ), '', 'a signature by another key gets no session' );

# --- a wrong origin and another site's RP ID -------------------------------------------------
$c = challenge($d);
is( session_cookie( signin( $d, PasskeyFixture::asserted( $K{-7}, challenge => $c->{challenge},
                origin => 'https://evil.example', rp => $HOST, count => 3 ) ) ), '',
    'an answer made for another origin gets no session' );
$c = challenge($d);
is( session_cookie( signin( $d, PasskeyFixture::asserted( $K{-7}, challenge => $c->{challenge},
                origin => $ORIGIN, rp => 'evil.example', count => 3 ) ) ), '',
    'an answer for another RP ID gets no session' );

# --- ruling 198: user verification is required ---------------------------------------------------
$c = challenge($d);
my $nouv = signin( $d, PasskeyFixture::asserted( $K{-7}, challenge => $c->{challenge}, origin => $ORIGIN,
        rp => $HOST, count => 3, flags => 0x01 ) );
is( session_cookie($nouv), '', 'an assertion without user verification gets no session' );
like( location($nouv), qr/error=passkey\b/, 'and is told the passkey was not accepted' );

# --- a challenge this site never issued -------------------------------------------------------
is( session_cookie( signin( $d, PasskeyFixture::asserted( $K{-7}, challenge => PasskeyFixture::b64u( 'x' x 32 ),
                origin => $ORIGIN, rp => $HOST, count => 3 ) ) ), '',
    'an answer to a made-up challenge gets no session' );

# --- the counter must move forward --------------------------------------------------------------
$c = challenge($d);
is( session_cookie( signin( $d, PasskeyFixture::asserted( $K{-7}, challenge => $c->{challenge},
                origin => $ORIGIN, rp => $HOST, count => 1 ) ) ), '',
    'a counter that did not move forward (a copied authenticator) gets no session' );
$c = challenge($d);
like( session_cookie( signin( $d, PasskeyFixture::asserted( $K{-7}, challenge => $c->{challenge},
                origin => $ORIGIN, rp => $HOST, count => 5 ) ) ), qr/\Aalice/,
    'the next counter does' );

# --- the other two algorithms -----------------------------------------------------------------
$c = challenge($d);
like( session_cookie( signin( $d, PasskeyFixture::asserted( $K{-257}, challenge => $c->{challenge},
                origin => $ORIGIN, rp => $HOST, count => 1 ) ) ), qr/\Aalice/, 'RS256 signs alice in' );
$c = challenge($d);
my %ed = PasskeyFixture::asserted( $K{-8}, challenge => $c->{challenge}, origin => $ORIGIN, rp => $HOST, count => 0 );
like( session_cookie( signin( $d, %ed ) ), qr/\Abob/,
    'Ed25519 signs bob in (an authenticator that keeps no counter sends 0)' );
is( session_cookie( signin( $d, %ed ) ), '',
    'and the same answer again gets no session: with no counter to catch it, the spent challenge does' );

# --- without CryptX ------------------------------------------------------------------------------
my $shadow = tempdir( CLEANUP => 1 );
make_path("$shadow/Crypt/PK");
{
    open my $fh, '>', "$shadow/Crypt/PK/ECC.pm" or die $!;
    print {$fh} "die qq{not installed (test shadow)\\n};\n";
    close $fh;
}
my $none = challenge( $d, env => { PERL5LIB => join ':', $shadow, ( $ENV{PERL5LIB} // () ) } );
ok( !$none->{ok}, 'without CryptX no challenge is issued' );
like( $none->{error} // '', qr/CryptX.*libcryptx-perl/, 'and the answer says what to install' );

done_testing();
