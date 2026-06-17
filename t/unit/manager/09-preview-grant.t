use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(run_script run_processor);
use Digest::SHA qw(hmac_sha256_hex);

# SM071 Phase 1: preview-grant minting. The manager API mints the signed
# lzs_preview cookie; the processor (06-preview.t) verifies it. This test
# covers the minting side and the end-to-end mint -> verify -> render chain.

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/layouts/base/themes/live");
make_path("$docroot/lazysite/layouts/base/themes/candidate");
make_path("$docroot/lazysite/auth");

open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print $cf "site_name: Test\nsite_url: http://localhost\nlayout: base\ntheme: live\n";
close $cf;

open my $lt, '>', "$docroot/lazysite/layouts/base/layout.tt" or die $!;
print $lt '<!DOCTYPE html><html><body>MARK:[% layout_name %]/[% theme_name %]:KRAM[% content %]</body></html>';
close $lt;

for my $t (qw(live candidate)) {
    open my $tj, '>', "$docroot/lazysite/layouts/base/themes/$t/theme.json" or die $!;
    print $tj qq({"name":"$t","layouts":["base"]});
    close $tj;
}

open my $idx, '>', "$docroot/index.md" or die $!;
print $idx "---\ntitle: Home\n---\nHome body.\n";
close $idx;
open my $nf, '>', "$docroot/404.md" or die $!;
print $nf "---\ntitle: NF\n---\nnf\n";
close $nf;

# Known auth secret; auth_user defaults to 'local' (no manager_groups).
my $secret = 'testsecret0123456789abcdef0123456789abcdef0123456789abcdef012345';
open my $sf, '>', "$docroot/lazysite/auth/.secret" or die $!;
print $sf "$secret\n";
close $sf;

# CSRF token as generate_csrf_token() computes it: csrf:<user>:<hour>.
sub csrf_token {
    my $user = shift;
    return hmac_sha256_hex( "csrf:$user:" . int( time() / 3600 ), $secret );
}

sub grant {
    my %p = @_;   # layout, theme, csrf (default valid), user (default local)
    my $user = $p{user} // 'local';
    my $token = exists $p{csrf} ? $p{csrf} : csrf_token($user);
    my $qs = "action=preview-grant&layout=$p{layout}&theme=$p{theme}";
    return run_script(
        'lazysite-manager-api.pl',
        env => {
            DOCUMENT_ROOT  => $docroot,
            REQUEST_METHOD => 'POST',
            QUERY_STRING   => $qs,
            CONTENT_LENGTH => 0,
            ( length $token ? ( HTTP_X_CSRF_TOKEN => $token ) : () ),
        },
    );
}

# --- Valid grant: Set-Cookie present, JSON ok, signature valid. ---
my $out = grant( layout => 'base', theme => 'candidate' );
like( $out, qr/Set-Cookie:\s*lzs_preview=/, 'grant: Set-Cookie emitted' );
like( $out, qr/"ok"\s*:\s*1/, 'grant: JSON ok' );

my ($cookie) = $out =~ /Set-Cookie:\s*lzs_preview=([^;]+)/;
ok( $cookie, 'grant: captured cookie value' );

my ( $payload, $sig ) = $cookie =~ /^(.+):([a-f0-9]{64})$/;
is( hmac_sha256_hex( $payload, $secret ), $sig, 'grant: signature valid' );
my ( $ver, $exp, $l, $t, $u ) = split /:/, $payload, 5;
is( $ver, 'v1',        'grant: payload version' );
is( $l,   'base',      'grant: payload layout' );
is( $t,   'candidate', 'grant: payload theme' );
is( $u,   'local',     'grant: payload user' );
ok( $exp > time(),     'grant: expiry in the future' );

# --- End to end: the minted cookie drives a preview render. ---
my $rendered = run_processor( $docroot, '/index',
    HTTP_COOKIE => "lzs_preview=$cookie" );
like( $rendered, qr{MARK:base/candidate:KRAM},
    'minted cookie drives a candidate-theme preview render' );
like( $rendered, qr/Cache-Control:\s*no-store/i, 'preview render is no-store' );

# --- Missing CSRF token: rejected, no cookie. ---
my $no_csrf = grant( layout => 'base', theme => 'candidate', csrf => '' );
unlike( $no_csrf, qr/Set-Cookie:\s*lzs_preview=/, 'no CSRF: no cookie set' );
like( $no_csrf, qr/CSRF/i, 'no CSRF: rejected with CSRF error' );

# --- Nonexistent layout: error, no cookie. ---
my $bad = grant( layout => 'nope', theme => 'candidate' );
unlike( $bad, qr/Set-Cookie:\s*lzs_preview=/, 'bad layout: no cookie' );
like( $bad, qr/No such layout/, 'bad layout: clear error' );

# --- Nonexistent theme under a real layout: error. ---
my $badt = grant( layout => 'base', theme => 'ghost' );
like( $badt, qr/No such theme/, 'bad theme: clear error' );

# --- Layout-only grant (empty theme) is allowed. ---
my $lonly = grant( layout => 'base', theme => '' );
like( $lonly, qr/Set-Cookie:\s*lzs_preview=/, 'empty theme: cookie set' );

# --- preview-clear expires the cookie. ---
my $clear = run_script(
    'lazysite-manager-api.pl',
    env => {
        DOCUMENT_ROOT    => $docroot,
        REQUEST_METHOD   => 'POST',
        QUERY_STRING     => 'action=preview-clear',
        CONTENT_LENGTH   => 0,
        HTTP_X_CSRF_TOKEN => csrf_token('local'),
    },
);
like( $clear, qr/Set-Cookie:\s*lzs_preview=;[^\n]*Max-Age=0/,
    'preview-clear: cookie expired (Max-Age=0)' );

done_testing();
