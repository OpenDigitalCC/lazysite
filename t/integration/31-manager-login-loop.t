#!/usr/bin/perl
# login-loop fix: an authenticated account WITHOUT the `ui` capability (e.g. moved
# into an mcp-only group) that reaches /manager/ must get a clear terminal 403 -
# NOT a 302 back to /login. Redirecting it would loop: /login sees the still-valid
# session and bounces it straight back to /manager/. An UNAUTHENTICATED request
# still redirects to /login (and clears the lzs_session marker, SM188).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor);

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/layouts/default");
make_path("$d/lazysite/auth");

open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
print $c "site_name: T\nlayout: default\nmanager: enabled\nauth_proxy_trusted: true\n";
close $c;

open my $l, '>', "$d/lazysite/layouts/default/layout.tt" or die $!;
print $l '<!DOCTYPE html><html><head><title>[% page_title %]</title></head>'
    . '<body><main>[% content %]</main></body></html>';
close $l;

open my $nf, '>', "$d/404.md" or die $!;
print $nf "---\ntitle: NF\n---\nNF.\n";
close $nf;

# A group that DOES grant `ui` (so the site genuinely grants manager access -
# the bootstrap-grace "any authenticated user is a manager" path is off) and a
# separate mcp-only group that does NOT.
open my $gs, '>', "$d/lazysite/auth/groups-settings.json" or die $!;
print $gs '{"admins":{"label":"Admins","ui":1},"mcp":{"label":"MCP","mcp":1}}';
close $gs;

# --- authenticated mcp-only account at /manager/ -> terminal 403, NOT a loop ----
{
    my $out = run_processor( $d, '/manager/',
        HTTP_X_REMOTE_USER => 'botty', HTTP_X_REMOTE_GROUPS => 'mcp' );
    like( $out, qr/Status: 403/, 'mcp-only account at /manager/ -> 403 (not a redirect)' );
    unlike( $out, qr{Location:[^\n]*login},
        'mcp-only account is NOT redirected to /login (no loop)' );
    like( $out, qr/not\s+permitted to use the manager/i,
        'the 403 explains the account cannot use the manager interface' );
    like( $out, qr/\bui\b/, 'the message names the ui capability as the remedy' );
}

# --- an unauthenticated request at /manager/ still bounces to /login (SM188) -----
{
    my $out = run_processor( $d, '/manager/' );
    like( $out, qr/Status: 302/, 'no auth at /manager/ -> 302' );
    like( $out, qr{Location:[^\n]*login}, 'no auth -> redirect to /login' );
    like( $out, qr/Set-Cookie:\s*lzs_session=;[^\n]*Max-Age=0/,
        'SM188: the no-auth bounce clears the lzs_session marker' );
}

# --- an account WITH the ui capability is not blocked by the forbidden page ------
{
    my $out = run_processor( $d, '/manager/',
        HTTP_X_REMOTE_USER => 'alice', HTTP_X_REMOTE_GROUPS => 'admins' );
    unlike( $out, qr/not\s+permitted to use the manager/i,
        'a ui-capable account is not shown the forbidden page' );
}

done_testing;
