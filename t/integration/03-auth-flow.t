#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_auth_site run_processor repo_root);
use File::Copy qw(copy);

my $docroot = tempdir( CLEANUP => 1 );
setup_auth_site($docroot);

# --- protected without auth → 302 to login ---
{
    my $out = run_processor( $docroot, '/protected' );
    like( $out, qr/Status: 302/,       'no auth → 302' );
    like( $out, qr{Location:[^\n]*login}, 'redirects toward login' );
}

# --- protected with valid user header → 200 ---
{
    my $out = run_processor( $docroot, '/protected',
        HTTP_X_REMOTE_USER   => 'alice',
        HTTP_X_REMOTE_GROUPS => 'members',
    );
    like( $out, qr/Status: 200/, 'valid auth → 200' );
}

# --- admins-only with wrong group → 403 ---
{
    my $out = run_processor( $docroot, '/admins-only',
        HTTP_X_REMOTE_USER   => 'bob',
        HTTP_X_REMOTE_GROUPS => 'members',
    );
    like( $out, qr/Status: 403/, 'wrong group → 403' );
}

# --- admins-only with correct group → 200 ---
{
    my $out = run_processor( $docroot, '/admins-only',
        HTTP_X_REMOTE_USER   => 'alice',
        HTTP_X_REMOTE_GROUPS => 'admins',
    );
    like( $out, qr/Status: 200/, 'correct group → 200' );
}


# --- login page is always accessible ---
{
    my $out = run_processor( $docroot, '/login' );
    like( $out, qr/Status: 200/, 'login page → 200 without auth' );
}

# --- SM052: shipped starter/login.md renders the next query param
# cleanly. The 0.2.15 version wrapped [% query.next | html %] in a
# <code> tag; render_content's code-block protection regex preserved
# the markers as literal text. Regression guard: render the shipped
# login.md with ?next=/members and assert the TT expression resolves
# in both the visible message AND the hidden input, with no literal
# [% query.next %] anywhere in the output.
{
    my $src = repo_root() . '/starter/login.md';
    # setup_auth_site writes a minimal stub login.md; overwrite with
    # the real shipped copy for this subtest.
    copy( $src, "$docroot/login.md" ) or die "copy login.md: $!";
    # /login?next=X is a query-carrying request; process_md skips the
    # cache for those, but clear any prior cache file to be certain.
    unlink "$docroot/login.html" if -f "$docroot/login.html";

    my $out = run_processor( $docroot, '/login',
        QUERY_STRING => 'next=/members',
    );

    like( $out, qr/Status: 200/, 'login?next=/members → 200' );
    like( $out, qr{<span class="login-context-url">/members</span>},
        'next value resolved in visible message' );
    like( $out, qr{<input type="hidden" name="next" value="/members">},
        'next value resolved in hidden input' );
    unlike( $out, qr{\[%\s*query\.next},
        'no literal [% query.next %] in output' );
}

done_testing();
