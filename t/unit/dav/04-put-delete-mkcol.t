#!/usr/bin/perl
# SM070: PUT, DELETE, MKCOL.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(setup_dav_site run_dav);
use Lazysite::Git ();

# --- PUT create / overwrite -------------------------------------------
{
    my $s = setup_dav_site();
    my $a = $s->{auth};

    my $c = run_dav( $s->{docroot}, 'PUT', '/content/p.md', body => "v1", HTTP_AUTHORIZATION => $a );
    is( $c->{code}, 201, 'PUT new => 201' );
    ok( -f "$s->{docroot}/content/p.md", 'file written' );

    my $o = run_dav( $s->{docroot}, 'PUT', '/content/p.md', body => "v2", HTTP_AUTHORIZATION => $a );
    is( $o->{code}, 204, 'PUT overwrite => 204' );

    open my $fh, '<', "$s->{docroot}/content/p.md"; my $body = do { local $/; <$fh> }; close $fh;
    is( $body, "v2", 'content updated' );
}

# --- RFC 4918 9.7.1: PUT under a MISSING parent => 409 (MKCOL it first) --------
# 0.9.3 restored the standard: the 0.9.x SM166 auto-mkcol (201) silently deviated
# from RFC 4918 and from the publishing brief (which teaches MKCOL-parents-first).
{
    my $s = setup_dav_site();
    # One missing level -> 409, nothing written.
    my $r = run_dav( $s->{docroot}, 'PUT', '/content/missing/p.md',
        body => "x", HTTP_AUTHORIZATION => $s->{auth} );
    is( $r->{code}, 409, 'PUT under a missing parent => 409 (RFC 4918 9.7.1)' );
    ok( !-e "$s->{docroot}/content/missing/p.md", 'nothing written under the missing parent' );

    # Several missing levels -> also 409, no partial chain (not a confusing 502).
    my $deep = run_dav( $s->{docroot}, 'PUT', '/content/a/b/c/deep.md',
        body => "y", HTTP_AUTHORIZATION => $s->{auth} );
    is( $deep->{code}, 409, 'PUT several levels deep => 409' );
    ok( !-e "$s->{docroot}/content/a", 'no partial parent chain was created' );

    # MKCOL the parent, THEN the PUT succeeds - the documented workflow.
    run_dav( $s->{docroot}, 'MKCOL', '/content/missing', HTTP_AUTHORIZATION => $s->{auth} );
    my $ok = run_dav( $s->{docroot}, 'PUT', '/content/missing/p.md',
        body => "x", HTTP_AUTHORIZATION => $s->{auth} );
    ok( $ok->{code} == 201 || $ok->{code} == 204, 'PUT succeeds once the parent exists' );
    ok( -f "$s->{docroot}/content/missing/p.md", 'the file is written after MKCOL' );
}

# --- PUT with a traversal parent is still refused (no auto-create escape) ---
{
    my $s = setup_dav_site();
    my $r = run_dav( $s->{docroot}, 'PUT', '/content/../../etc/p.md',
        body => "x", HTTP_AUTHORIZATION => $s->{auth} );
    isnt( $r->{code}, 201, 'a traversal PUT is not created' );
    ok( !-e "$s->{docroot}/../../etc/p.md", 'nothing written outside the docroot' );
}

# --- oversize CONTENT_LENGTH rejected before reading ------------------
{
    my $s = setup_dav_site( conf => "webdav_enabled: true\nmanager_upload_max_mb: 1\n" );
    my $r = run_dav( $s->{docroot}, 'PUT', '/content/big.md',
        body => "x", CONTENT_LENGTH => 5 * 1024 * 1024, HTTP_AUTHORIZATION => $s->{auth} );
    is( $r->{code}, 413, 'oversize declared length => 413' );
    ok( !-f "$s->{docroot}/content/big.md", 'nothing written for rejected upload' );
}

# --- no temp file left behind on a normal write -----------------------
{
    my $s = setup_dav_site();
    run_dav( $s->{docroot}, 'PUT', '/content/clean.md', body => "ok", HTTP_AUTHORIZATION => $s->{auth} );
    opendir my $dh, "$s->{docroot}/content"; my @tmp = grep { /\.tmp\./ } readdir $dh; closedir $dh;
    is( scalar @tmp, 0, 'no .tmp. artefacts remain after PUT' );
}

# --- MKCOL ------------------------------------------------------------
{
    my $s = setup_dav_site();
    my $a = $s->{auth};

    my $ok = run_dav( $s->{docroot}, 'MKCOL', '/content/dir', HTTP_AUTHORIZATION => $a );
    is( $ok->{code}, 201, 'MKCOL => 201' );
    ok( -d "$s->{docroot}/content/dir", 'directory created' );

    my $dup = run_dav( $s->{docroot}, 'MKCOL', '/content/dir', HTTP_AUTHORIZATION => $a );
    is( $dup->{code}, 405, 'MKCOL on existing => 405' );

    my $deep = run_dav( $s->{docroot}, 'MKCOL', '/content/x/y', HTTP_AUTHORIZATION => $a );
    is( $deep->{code}, 409, 'MKCOL with missing parent => 409' );

    my $body = run_dav( $s->{docroot}, 'MKCOL', '/content/withbody',
        body => "stuff", HTTP_AUTHORIZATION => $a );
    is( $body->{code}, 415, 'MKCOL with a body => 415' );
}

# --- DELETE file / dir / missing --------------------------------------
{
    my $s = setup_dav_site();
    my $a = $s->{auth};
    run_dav( $s->{docroot}, 'PUT', '/content/d.md', body => "x", HTTP_AUTHORIZATION => $a );
    my $df = run_dav( $s->{docroot}, 'DELETE', '/content/d.md', HTTP_AUTHORIZATION => $a );
    is( $df->{code}, 204, 'DELETE file => 204' );
    ok( !-e "$s->{docroot}/content/d.md", 'file gone' );

    run_dav( $s->{docroot}, 'MKCOL', '/content/dd', HTTP_AUTHORIZATION => $a );
    run_dav( $s->{docroot}, 'PUT', '/content/dd/inner.md', body => "x", HTTP_AUTHORIZATION => $a );
    my $dd = run_dav( $s->{docroot}, 'DELETE', '/content/dd', HTTP_AUTHORIZATION => $a );
    is( $dd->{code}, 204, 'DELETE collection => 204' );
    ok( !-e "$s->{docroot}/content/dd", 'collection and contents gone' );

    my $miss = run_dav( $s->{docroot}, 'DELETE', '/content/ghost.md', HTTP_AUTHORIZATION => $a );
    is( $miss->{code}, 404, 'DELETE missing => 404' );
}

# --- cache invalidation on write/delete -------------------------------
{
    my $s = setup_dav_site();
    my $a = $s->{auth};
    run_dav( $s->{docroot}, 'PUT', '/content/cached.md', body => "x", HTTP_AUTHORIZATION => $a );
    # simulate a rendered cache file
    open my $cf, '>', "$s->{docroot}/content/cached.html"; print $cf "<html>"; close $cf;
    run_dav( $s->{docroot}, 'PUT', '/content/cached.md', body => "y", HTTP_AUTHORIZATION => $a );
    ok( !-e "$s->{docroot}/content/cached.html", 'PUT drops stale rendered cache' );
}

# --- SM085: a DAV PUT/DELETE commits to the content history when enabled ------
SKIP: {
    skip 'git not installed on this host', 6 unless Lazysite::Git::git_available();
    my $s = setup_dav_site( conf => "webdav_enabled: true\ngit_history: enabled\n" );
    my $d = $s->{docroot};
    ok( Lazysite::Git::init( $d, 'installer' )->{ok}, 'content history initialised' );

    my $c = run_dav( $d, 'PUT', '/content/tracked.md', body => "v1",
        HTTP_AUTHORIZATION => $s->{auth} );
    is( $c->{code}, 201, 'PUT succeeds with git history on' );
    my $log = Lazysite::Git::file_log( $d, 'content/tracked.md' );
    is( scalar @{$log}, 1, 'the PUT committed' );
    is( $log->[0]{subject}, 'create content/tracked.md', 'terse create message' );
    is( $log->[0]{author}, $s->{user}, 'commit attributed to the DAV user' );

    run_dav( $d, 'DELETE', '/content/tracked.md', HTTP_AUTHORIZATION => $s->{auth} );
    my $log2 = Lazysite::Git::file_log( $d, 'content/tracked.md' );
    is( $log2->[0]{subject}, 'delete content/tracked.md', 'the DELETE committed too' );
}

done_testing();
