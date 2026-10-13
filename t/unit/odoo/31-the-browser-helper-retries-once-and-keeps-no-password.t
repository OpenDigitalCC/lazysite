#!/usr/bin/perl
# SM747 D (OA6): the one browser module that talks to the Odoo endpoint -
# fetch, the CSRF token with ONE retry, the sign-in prompt, and the regions that
# fill from a binding - so that no page writes its own and gets those wrong.
#
# What can go wrong in such a module is that it loops, leaks or doubles a send:
#   * a stale token is fetched again and the POST sent once more - ONCE;
#   * a sign-in the endpoint asks for is asked of the person once and the call
#     sent once more - so a wrong password cannot make it loop;
#   * the password is in the body of ONE POST and nowhere else: not a URL, a
#     header, a later request or the result;
#   * what Odoo returned goes into the page as text, never as markup, and the
#     script keeps nothing between page loads.
# The first three are run under node with a fake fetch that records every
# request; the last two are held against the source, which is what a reviewer
# of this file would read.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root  = repo_root();
my $asset = "$root/starter/assets/lazysite-odoo.js";
ok( -f $asset, 'the helper is a shipped asset' ) or BAIL_OUT('starter/assets/lazysite-odoo.js is missing');

my $js = do { open my $fh, '<', $asset or die $!; local $/; <$fh> };

subtest 'the source holds no storage, no markup from Odoo, no eval, no logging' => sub {
    my $code = $js;
    $code =~ s{/\*.*?\*/}{}gs;    # the comments say what it does not do
    for my $bad (qw(localStorage sessionStorage indexedDB document.cookie innerHTML outerHTML insertAdjacentHTML document.write eval Function console)) {
        ok( index( $code, $bad ) < 0, "no $bad" );
    }
    unlike( $code, qr/new\s+Function|setTimeout\s*\(\s*['"]/, 'no string-built code' );
    like( $code, qr/textContent/, 'values go in as text' );
    my $cleared = () = $code =~ /pass\.value\s*=\s*''/g;
    cmp_ok( $cleared, '>=', 2, 'the password box is cleared on submit, before the answer, and on close' );
    like( $code, qr/type:\s*'password'/, 'the box is a password box' );
    like( $code, qr/autocomplete:\s*'current-password'/, 'and says what it is, so a password manager can fill it' );
    unlike( $code, qr/['"]password['"]\s*\+|password\s*\+\s*['"]|\?\s*password|&password/, 'the password is never put in a URL' );
};

my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null`;
chomp $node;
SKIP: {
    skip 'node is not installed', 2 unless length $node && -x $node;

    my $err = `$node --check "$asset" 2>&1`;
    is( $?, 0, 'it parses' ) or diag $err;

    my $out = `$node "$root/t/lib/odoo-helper-harness.js" "$asset" 2>&1`;
    my $f   = eval { decode_json($out) };
    ok( $f && !$f->{error}, 'the behaviour harness ran' ) or BAIL_OUT("harness: $out");

    subtest 'a read is a GET, same-origin, with the fields as the query' => sub {
        is( $f->{read}{n},      1,     'one request' );
        is( $f->{read}{method}, 'GET', 'a GET' );
        like( $f->{read}{url}, qr{\A/cgi-bin/lazysite-odoo\.pl\?}, 'to the endpoint' );
        like( $f->{read}{url}, qr/binding=shop-list/,              'naming the binding' );
        like( $f->{read}{url}, qr/q=a%20b%26c/,                    'a value is encoded' );
        is( $f->{read}{credentials}, 'same-origin', 'the cookies of this origin only' );
    };

    subtest 'a stale token: fetched again, the POST sent once more, never a third time' => sub {
        is( $f->{csrf_retry}{status}, 200, 'it recovers' );
        is_deeply( $f->{csrf_retry}{posts}, [ 'T1', 'T2' ], 'the second POST carries the fresh token' );
        is( $f->{csrf_retry}{token_fetches}, 2, 'two token fetches' );
        is( $f->{csrf_twice}{posts},         2, 'refused twice: two POSTs and no more' );
        is( $f->{csrf_twice}{status},  403, 'and the refusal is returned' );
        is( $f->{token_once}{fetches}, 1,   'tokens are fetched once for several POSTs' );
    };

    subtest 'a sign-in is asked of the person once, and the call sent once more' => sub {
        is( $f->{signin_loop}{asked}, 1, 'asked once' );
        is( $f->{signin_loop}{gets},  2, 'two requests: the call, and the call again' );
        is( $f->{signin_loop}{status}, 401, 'a second refusal is returned, not looped on' );
        is( $f->{prompt_why}, 'sign in', 'the server\'s words are what the person is shown' );
        is( $f->{signin_then_ok}{status}, 200, 'and when it works, it works' );
        is( $f->{signin_then_ok}{gets},   2,   'on the second request' );
        is( $f->{cancelled}{gets},        1,   'cancelled: the call is not sent again' );
        is( $f->{cancelled}{status},      401, 'and the refusal is returned' );
        is( $f->{no_prompt}{asked},       0,   'a caller can ask for no prompt' );
        is( $f->{write_signin}{posts},    2,   'a write is sent again once' );
        is( $f->{write_signin}{status},   200, 'and goes through' );
    };

    subtest 'the password is in the body of one POST and nowhere else' => sub {
        is( $f->{signin}{status}, 200,    'signed in' );
        is( $f->{signin}{name},   'Jane', 'and the name for a greeting comes back' );
        ok( $f->{signin}{body}{signin}, 'a sign-in POST' );
        is( $f->{signin}{body}{login},         'jane@example.com', 'with the login' );
        is( $f->{signin}{body}{visitor_token}, 'VT', 'and the visitor token' );
        is( $f->{signin}{password_in_posts}, 1, 'the password is in exactly one request' );
        ok( !$f->{signin}{in_url_or_headers},   'in no URL and no header' );
        ok( !$f->{signin}{result_has_password}, 'and not in what comes back' );
        is( $f->{signout}{body}{signout}, JSON::PP::true, 'sign-out is a POST with its token' );
    };

    subtest 'a region fills what the server drew, as text, and nothing it refused' => sub {
        is( $f->{fill}{name}, '<b>x</b>', 'a value is text, whatever it looks like' );
        is( $f->{fill}{note}, 'unset', 'a field the server refused to draw is not filled' );
        is( $f->{fill}{obj}, '{"a":1}', 'an object is shown as its JSON, not as [object Object]' );
        is( $f->{fill}{nul},     '',      'null is blank' );
        is( $f->{fill}{missing}, 'unset', 'a field with no value is left alone' );
        is_deeply( $f->{fill_all}, { name => 'a', note => 'b' }, 'with no descriptors, every named slot is filled' );
    };

    subtest 'a bad answer is data, and a request that cannot be made rejects' => sub {
        is( $f->{not_json}{status}, 502,   'the status is kept' );
        is( $f->{not_json}{data},   undef, 'and data is null, with no throw' );
        ok( $f->{offline}{rejected}, 'a failed request rejects, for the caller to decide' );
    };
}

done_testing();
