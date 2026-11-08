#!/usr/bin/perl
# SM1322 (ruling 49, T-07): /LOGIN ASKS THE SERVER WHETHER THE SESSION IS HONOURED.
#
# "Signed in" on /login was judged from the lzs_session display marker alone
# (lazysite-chrome.js), which lives for the whole session lifetime. A session since
# revoked or expired, or an Odoo session gone odoo-stale (no groups), kept it, and the
# page said "You are already signed in" with no sign-in form to a visitor the site had
# just refused. Now the page's panel carries data-ls-auth-check and the chrome script
# asks GET /cgi-bin/lazysite-auth.pl?action=session, which answers request_session's
# verdict and clears the marker when it is no.
#
#   - the server: a valid session is yes; none, an expired, a mis-signed and an unknown
#     account's are no, and clear the marker; a fresh Odoo session is yes; a stale one
#     goes through the Odoo endpoint's renewal step (SM1381), which answers. The
#     answer is never cached.
#   - the script (under node, t/lib/auth-check-harness.js): a no clears the marker and
#     shows the sign-in; a yes, an error and no answer leave the page as drawn; a page
#     without data-ls-auth-check, or a visitor without the marker, asks nothing.
#   - the login page carries the attribute on its "already signed in" panel.
#   - ruling 85: the panel offers "Sign in as someone else", the sign-out with
#     ?then=signin and the page's ?next=; it revokes the session and lands on /login
#     with next (a path on this site, or none). A plain sign-out lands on /logout.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use JSON::PP    qw(decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir setup_minimal_site add_account grant_caps env_passthrough run_child);
use OdooTest qw(enable_odoo);
use Lazysite::Auth::Session ();

my $root = repo_root();
my $d    = site_tempdir();
setup_minimal_site($d);
my $LZ = "$d/lazysite";
make_path( "$LZ/auth", "$LZ/logs", "$LZ/cache" );
my $SECRET = 'b' x 64;
{
    open my $fh, '>', "$LZ/auth/.secret" or die $!;
    print {$fh} "$SECRET\n";
    close $fh;
    chmod 0600, "$LZ/auth/.secret";
}
add_account( $d, 'alice' );
grant_caps( $d, 'boss', 'ui' );    # a secured site: an Odoo session is an identity only there
# SM1369 X4: the Odoo sign-in is an identity provider the extension declares - it is
# indexed, and on, or it signs nobody in (off means off)
enable_odoo($d);
{
    open my $fh, '>', "$LZ/odoo.conf" or die $!;
    print {$fh} "odoo_site_signin: on\nodoo_group_map: base.group_user = staff\nodoo_identity_ttl: 60\n";
    close $fh;
}

sub cookie_for {
    my ( $user, %o ) = @_;
    my $payload = join ':', $user, ( $o{ts} // time() ), substr( hmac_sha256_hex( "sid-$user", 'x' ), 0, 16 ), '';
    my $sig = $o{bad_sig} ? ( 'f' x 64 ) : hmac_sha256_hex( $payload, $SECRET );
    return "lazysite_auth=$payload:$sig; lzs_session=1";
}

sub ask {
    my ( $cookie, %o ) = @_;
    local %ENV = (
        env_passthrough(),
        DOCUMENT_ROOT  => $d,
        REDIRECT_URL   => '/cgi-bin/lazysite-auth.pl',
        REQUEST_METHOD => $o{method} // 'GET',
        QUERY_STRING   => 'action=session',
        REMOTE_ADDR    => '192.0.2.5',
        HTTP_HOST      => 'site.test',
        ( defined $cookie ? ( HTTP_COOKIE => $cookie ) : () ),
    );
    my $out = run_child( [ $^X, "$root/lazysite-auth.pl" ] )->{out} // '';
    my ( $head, $body ) = split /\r?\n\r?\n/, $out, 2;
    return { head => $head // '', body => ( eval { decode_json( $body // '' ) } // {} ), raw => $out };
}

my $CLEAR = qr/^Set-Cookie:\s*lzs_session=;[^\n]*Max-Age=0/mi;

subtest 'the server answers whether it honours the session' => sub {
    my $r = ask( cookie_for('alice') );
    ok( $r->{body}{ok} && $r->{body}{signed_in}, 'a valid session: signed in' ) or diag( $r->{raw} );
    like( $r->{head}, qr/^Content-Type: application\/json/mi, '...as JSON' );
    like( $r->{head}, qr/^Cache-Control: no-store/mi, '...never cached' );
    unlike( $r->{head}, $CLEAR, '...and the marker is left' );

    my %no = (
        'no session cookie'           => 'lzs_session=1',
        'an expired session'          => cookie_for( 'alice', ts => time() - 400 * 86400 ),
        'a mis-signed cookie'         => cookie_for( 'alice', bad_sig => 1 ),
        'an account that is not there' => cookie_for('ghost'),
    );
    for my $what ( sort keys %no ) {
        my $n = ask( $no{$what} );
        ok( $n->{body}{ok} && exists $n->{body}{signed_in} && !$n->{body}{signed_in}, "$what: not signed in" )
            or diag( $n->{raw} );
        like( $n->{head}, $CLEAR, "$what: the marker is cleared" );
    }
    my $none = ask(undef);
    ok( !$none->{body}{signed_in}, 'no cookie at all: not signed in' );
    is_deeply( [ sort keys %{ $r->{body} } ], [qw(ok signed_in)], 'the answer says yes or no, and nothing of why' );
};

subtest 'an Odoo session gone stale is refused, a fresh one honoured' => sub {
    local $Lazysite::Auth::Session::LAZYSITE_DIR = $LZ;
    my ($fresh) = Lazysite::Auth::Session::mint_provider_session( provider => 'odoo', login => 'jane@example.com', name => 'Jane', groups => ['staff'] );
    my ($stale) = Lazysite::Auth::Session::mint_provider_session( provider => 'odoo', login => 'kim@example.com', name => 'Kim',
        groups => ['staff'], now => time() - 600 );
    ok( $fresh && $stale, 'two Odoo sessions minted' );
    my $f = ask("lazysite_auth=$fresh; lzs_session=1");
    ok( $f->{body}{signed_in}, 'checked within odoo_identity_ttl: signed in' ) or diag( $f->{raw} );
    unlike( $f->{head}, $CLEAR, '...marker kept' );
    # SM1381: checked longer ago than odoo_identity_ttl, it is not answered signed out:
    # it goes through the Odoo endpoint's renewal step, which gives this same answer
    # once it has asked Odoo (t/unit/odoo/135).
    my $s = ask("lazysite_auth=$stale; lzs_session=1");
    like( $s->{head}, qr/^Status: 303/mi, 'checked longer ago than odoo_identity_ttl: sent to be renewed' )
        or diag( $s->{raw} );
    like( $s->{head}, qr{^Location: /cgi-bin/lazysite-odoo\.pl\?renew=1&answer=session\r?$}mi,
        '...at the Odoo endpoint, for this answer' );
    unlike( $s->{head}, $CLEAR, '...the marker is left to the renewal step' );
    unlike( $s->{head}, qr/^Set-Cookie:\s*lazysite_auth=/mi, '...the session cookie is left to the Odoo endpoint' );
};

subtest 'the login page asks' => sub {
    open my $fh, '<', "$root/starter/lazysite/templates/system/login.md" or die $!;
    my $page = do { local $/; <$fh> };
    like( $page, qr/<div[^>]*\bdata-ls-auth-out\b[^>]*\bdata-ls-auth-check\b[^>]*>\s*<p><strong>You are already signed in/,
        'the "already signed in" panel carries data-ls-auth-check' );
};

subtest 'ruling 85: "Sign in as someone else" signs out and returns to the form with next' => sub {
    # the page: the panel's link, rendered as the processor renders the page (TT)
    require Template;
    open my $fh, '<', "$root/starter/lazysite/templates/system/login.md" or die $!;
    my ($body) = do { local $/; <$fh> } =~ /\A---\n.*?\n---\n(.*)\z/s;
    my $render = sub {
        my ($q) = @_;
        my $out = '';
        Template->new->process( \$body, { query => $q }, \$out ) or die Template->error;
        my ($panel) = $out =~ /(<div[^>]*data-ls-auth-check.*?<\/div>)/s;
        return $panel // '';
    };
    my $p = $render->( { next => '/members' } );
    like( $p, qr{<a href="/cgi-bin/lazysite-auth\.pl\?action=logout&amp;then=signin&amp;next=%2Fmembers" data-ls-signin-other>Sign in as someone else</a>},
        'the signed-in panel offers it, carrying ?next=' );
    like( $render->( {} ), qr{href="/cgi-bin/lazysite-auth\.pl\?action=logout&amp;then=signin" data-ls-signin-other>},
        '...and without a next, carries none' );

    # the server: that request signs out (the session is revoked) and lands on the form
    my $c   = cookie_for('alice');
    my $out = sub {
        my ($qs) = @_;
        local %ENV = ( env_passthrough(), DOCUMENT_ROOT => $d, REDIRECT_URL => '/cgi-bin/lazysite-auth.pl',
            REQUEST_METHOD => 'GET', QUERY_STRING => $qs, REMOTE_ADDR => '192.0.2.5', HTTP_HOST => 'site.test',
            HTTP_COOKIE => $c );
        return run_child( [ $^X, "$root/lazysite-auth.pl" ] )->{out} // '';
    };
    ok( ask($c)->{body}{signed_in}, 'signed in before (control)' );
    my $r = $out->('action=logout&then=signin&next=%2Fmembers');
    like( $r, qr/^Status: 302/m, 'it is the sign-out' );
    like( $r, qr{^Location: /login\?next=/members\r?$}m, '...landing on /login with next' );
    like( $r, qr/^Set-Cookie:\s*lazysite_auth=;[^\n]*Max-Age=0/m, '...the session cookie cleared' );
    like( $r, $CLEAR, '...and the marker' );
    ok( !ask($c)->{body}{signed_in}, 'the old session is no longer honoured (revoked, not only forgotten)' );
    $c = cookie_for('alice');
    like( $out->('action=logout&then=signin&next=%2F%2Fevil.example%2F'), qr{^Location: /login\r?$}m,
        'a next that is not a path on this site is dropped' );
    like( $out->('action=logout&next=%2Fmembers'), qr{^Location: /logout\r?$}m, 'a plain sign-out still lands on /logout' );
};

SKIP: {
    chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
    skip 'node is not installed', 1 unless length $node && -x $node;
    subtest 'the script clears the marker on a refusal and leaves the page otherwise' => sub {
        my $r = run_child( [ $node, "$root/t/lib/auth-check-harness.js", "$root/starter/assets/lazysite-chrome.js" ],
            stderr => 'merge' );
        my $f = eval { decode_json( $r->{out} ) };
        ok( $f && !$f->{error}, 'the harness ran' ) or BAIL_OUT( 'harness: ' . ( $r->{out} // '' ) );

        is_deeply( $f->{refused_before}, { panel => '', form => 'none' }, 'the marker draws "signed in" first' );
        is( scalar @{ $f->{refused}{fetched} }, 1, 'the page asks once' );
        is( $f->{refused}{fetched}[0]{url}, '/cgi-bin/lazysite-auth.pl?action=session', '...the session check' );
        is( $f->{refused}{fetched}[0]{credentials}, 'same-origin', '...with the session cookie' );
        is( $f->{refused}{fetched}[0]{cache}, 'no-store', '...uncached' );
        is( $f->{refused}{marker}, undef, 'refused: the marker is cleared' );
        ok( $f->{refused}{session_cookie_kept}, '...and nothing else' );
        is( $f->{refused}{form}, '', '...the sign-in form shows' );
        is( $f->{refused}{panel}, 'none', '...and "already signed in" does not' );

        is( $f->{honoured}{marker}, '1', 'honoured: the marker stays' );
        is_deeply( [ @{ $f->{honoured} }{qw(panel form)} ], [ '', 'none' ], '...and "already signed in" shows' );

        for my $c (qw(server_error unreachable no_answer)) {
            is( $f->{$c}{marker}, '1', "$c: the marker stays" );
            is_deeply( [ @{ $f->{$c} }{qw(panel form)} ], [ '', 'none' ], "$c: the page is as the marker drew it" );
        }
        is_deeply( $f->{unchecked}{fetched}, [], 'a page without data-ls-auth-check asks nothing' );
        is( $f->{unchecked}{marker}, '1', '...and keeps the marker' );
        is_deeply( $f->{no_marker}{fetched}, [], 'a visitor without the marker asks nothing' );
        is_deeply( [ @{ $f->{no_marker} }{qw(panel form)} ], [ 'none', '' ], '...and sees the sign-in' );
    };
}

done_testing();
