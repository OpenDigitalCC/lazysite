#!/usr/bin/perl
# Pin the behaviour of the helpers extracted out of main(). These
# were previously inline blocks; tests ensure the extraction is
# behaviourally equivalent and stays that way.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);
load_processor($docroot);

# --- parse_query_string ---
{
    my $h = main::parse_query_string('');
    is_deeply( $h, {}, 'empty string -> empty hash' );

    $h = main::parse_query_string(undef);
    is_deeply( $h, {}, 'undef -> empty hash' );

    $h = main::parse_query_string('a=1&b=2');
    is_deeply( $h, { a => 1, b => 2 }, 'two simple pairs' );

    $h = main::parse_query_string('name=Hello+World');
    is( $h->{name}, 'Hello World', '+ decodes to space' );

    $h = main::parse_query_string('x=%E2%9C%93');
    # %E2%9C%93 is U+2713 encoded as UTF-8. After percent-decode
    # we re-decode as UTF-8 so the stored value is the Unicode
    # code point, not three Latin-1 bytes.
    is( $h->{x}, "\x{2713}",
        'percent-encoded UTF-8 decoded to Unicode code point' );

    # Malformed UTF-8 must not crash - falls back to raw bytes.
    $h = main::parse_query_string('x=%FF%FE');
    is( $h->{x}, "\xFF\xFE",
        'invalid UTF-8 sequence falls back to raw bytes' );

    $h = main::parse_query_string('x=<script>');
    is( $h->{x}, '&lt;script&gt;', 'value HTML-escaped' );

    $h = main::parse_query_string('x=a&&y=b');
    is_deeply( $h, { x => 'a', y => 'b' },
              'empty pair between delimiters ignored' );

    $h = main::parse_query_string('bare');
    is( $h->{bare}, '', 'bare key gets empty value' );
}

# --- is_auth_surface ---
# This reads auth_redirect out of site vars, which was written by
# setup_minimal_site with no override, so default /login applies.
{
    ok(  main::is_auth_surface('/login'),            '/login is auth surface' );
    ok(  main::is_auth_surface('/login/reset'),      'sub-path of /login is' );
    ok(  main::is_auth_surface('/logout'),           '/logout is auth surface' );
    ok(  main::is_auth_surface('/logout/confirm'),   'sub-path of /logout is' );
    ok( !main::is_auth_surface('/'),                 '/ is not' );
    ok( !main::is_auth_surface('/about'),            '/about is not' );
    ok( !main::is_auth_surface('/login-page'),       '/login-page is NOT (no slash)' );
}

# --- try_serve_cache ---
# Craft a docroot where cache exists and is fresh; verify that
# try_serve_cache returns truthy and outputs the cached body.
{
    open my $fh, '>', "$docroot/cached.md" or die $!;
    print $fh "---\ntitle: C\n---\nMD BODY\n";
    close $fh;
    open $fh, '>', "$docroot/cached.html" or die $!;
    print $fh "CACHED BODY MARKER";
    close $fh;
    # Make HTML newer than MD so mtime check passes
    utime time + 2, time + 2, "$docroot/cached.html";

    my @md_stat   = stat("$docroot/cached.md");
    my @html_stat = stat("$docroot/cached.html");

    # Capture STDOUT
    my $captured = '';
    open my $oldout, '>&', \*STDOUT;
    close STDOUT;
    open STDOUT, '>', \$captured;

    my $served = main::try_serve_cache(
        'cached',
        "$docroot/cached.md",
        "$docroot/cached.html",
        \@html_stat, \@md_stat
    );

    close STDOUT;
    open STDOUT, '>&', $oldout;

    ok( $served, 'try_serve_cache returned truthy on fresh cache' );
    like( $captured, qr/CACHED BODY MARKER/,
          'cached body written to STDOUT' );
    like( $captured, qr/Status: 200 OK/,
          'status header emitted' );
}

# --- try_serve_cache returns false when cache stale (no ttl) ---
{
    open my $fh, '>', "$docroot/stale.md" or die $!;
    print $fh "---\ntitle: S\n---\nMD\n";
    close $fh;
    open $fh, '>', "$docroot/stale.html" or die $!;
    print $fh "OLD CACHE";
    close $fh;
    # Cache older than md
    utime time - 100, time - 100, "$docroot/stale.html";

    my @md_stat   = stat("$docroot/stale.md");
    my @html_stat = stat("$docroot/stale.html");

    my $captured = '';
    open my $oldout, '>&', \*STDOUT;
    close STDOUT;
    open STDOUT, '>', \$captured;

    my $served = main::try_serve_cache(
        'stale',
        "$docroot/stale.md",
        "$docroot/stale.html",
        \@html_stat, \@md_stat
    );

    close STDOUT;
    open STDOUT, '>&', $oldout;

    ok( !$served, 'stale cache (no ttl) -> not served' );
    is( $captured, '', 'no output on stale cache' );
}

# --- apply_trust_gate keeps trusted headers, strips untrusted ---
{
    local %ENV = %ENV;
    $ENV{HTTP_X_REMOTE_USER} = 'spoofed';
    $ENV{HTTP_X_REMOTE_GROUPS} = 'admins';
    # No sentinel, no conf override -> untrusted
    delete $ENV{LAZYSITE_AUTH_TRUSTED};

    # Silence stderr: apply_trust_gate logs a WARN on untrusted
    open my $olderr, '>&', \*STDERR;
    close STDERR;
    open STDERR, '>', '/dev/null';

    main::apply_trust_gate('/some/path');

    close STDERR;
    open STDERR, '>&', $olderr;

    ok( !exists $ENV{HTTP_X_REMOTE_USER},
        'untrusted X-Remote-User stripped' );
    ok( !exists $ENV{HTTP_X_REMOTE_GROUPS},
        'untrusted X-Remote-Groups stripped' );
}

{
    local %ENV = %ENV;
    $ENV{HTTP_X_REMOTE_USER} = 'alice';
    $ENV{HTTP_X_REMOTE_GROUPS} = 'admins';
    $ENV{LAZYSITE_AUTH_TRUSTED} = '1';    # sentinel -> trusted

    main::apply_trust_gate('/some/path');

    is( $ENV{HTTP_X_REMOTE_USER}, 'alice',
        'trusted sentinel: X-Remote-User kept' );
    is( $ENV{HTTP_X_REMOTE_GROUPS}, 'admins',
        'trusted sentinel: X-Remote-Groups kept' );
}

done_testing();
