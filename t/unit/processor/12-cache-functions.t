#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);
make_path("$docroot/lazysite/cache/ct");
load_processor($docroot);

# --- ct_cache_path derives path with colon-delimited key ---
is( main::ct_cache_path('api/status'),
    "$docroot/lazysite/cache/ct/api:status.ct",
    'slashes in base become colons in cache file name' );
is( main::ct_cache_path('index'),
    "$docroot/lazysite/cache/ct/index.ct",
    'single-segment key has no colon' );

# --- write_ct / read_ct round-trip for non-default content types ---
{
    main::write_ct( 'api/status', 'application/json; charset=utf-8' );
    ok( -f "$docroot/lazysite/cache/ct/api:status.ct",
        'ct cache file written' );
    is( main::read_ct('api/status'),
        'application/json; charset=utf-8',
        'read_ct returns value written' );
}

# --- write_ct suppressed for default text/html ---
{
    main::write_ct( 'normal/page', 'text/html; charset=utf-8' );
    ok( !-f "$docroot/lazysite/cache/ct/normal:page.ct",
        'default html content type not persisted' );
}

# --- read_ct returns undef when file missing ---
is( main::read_ct('nonexistent/page'), undef,
    'read_ct returns undef when file absent' );

# --- write_html honours LAZYSITE_NOCACHE ---
{
    my $html_path = "$docroot/test.html";
    local $ENV{LAZYSITE_NOCACHE} = '1';
    main::write_html( $html_path, '<html>ok</html>' );
    ok( !-f $html_path, 'LAZYSITE_NOCACHE suppresses cache write' );
}

# --- write_html writes file when NOCACHE unset ---
{
    my $html_path = "$docroot/test.html";
    delete local $ENV{LAZYSITE_NOCACHE};
    main::write_html( $html_path, '<html>ok</html>' );
    ok( -f $html_path, 'cache file written when NOCACHE unset' );
    open my $fh, '<', $html_path;
    my $c = do { local $/; <$fh> };
    close $fh;
    like( $c, qr/<html>ok/, 'content written correctly' );
    unlink $html_path;
}

# --- write_html refuses zero-byte content ---
{
    my $html_path = "$docroot/empty.html";
    delete local $ENV{LAZYSITE_NOCACHE};
    main::write_html( $html_path, '' );
    ok( !-f $html_path,
        'zero-byte content refused (prevents permanent blocker)' );
}

# --- write_ct with undef removes stale entry ---
{
    my $ct_path = "$docroot/lazysite/cache/ct/stale:page.ct";
    make_path("$docroot/lazysite/cache/ct") unless -d "$docroot/lazysite/cache/ct";
    open my $fh, '>', $ct_path; print $fh 'stale'; close $fh;
    ok( -f $ct_path, 'stale ct file exists' );
    main::write_ct( 'stale/page', undef );
    ok( !-f $ct_path, 'undef content type deletes stale ct entry' );
}

done_testing();
