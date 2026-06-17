#!/usr/bin/perl
# SM070: lazysite-dav.pl path resolution, internal-tree denial,
# blocked paths, scope confinement, symlink containment.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_dav_site run_dav);

# --- traversal / null / control rejected ------------------------------
{
    my $s = setup_dav_site();
    my $a = $s->{auth};

    my $trav = run_dav( $s->{docroot}, 'GET', '/content/../lazysite/auth/users',
        HTTP_AUTHORIZATION => $a );
    ok( $trav->{code} >= 400 && $trav->{code} < 500, 'dot-dot traversal rejected (4xx)' );
    isnt( $trav->{body}, "root:x", 'traversal did not read outside docroot' );

    my $nul = run_dav( $s->{docroot}, 'GET', "/content/x\0.md", HTTP_AUTHORIZATION => $a );
    ok( $nul->{code} >= 400, 'null byte in path rejected' );

    # A literal "%2e%2e" segment is NOT url-decoded by the script (the
    # web server already decoded PATH_INFO), so it is an ordinary
    # missing filename, not traversal.
    my $enc = run_dav( $s->{docroot}, 'GET', '/content/%2e%2e/secret',
        HTTP_AUTHORIZATION => $a );
    is( $enc->{code}, 404, 'literal %2e%2e treated as a name, resolves to 404 not escape' );
}

# --- internal-tree denial (whole lazysite/) ---------------------------
{
    my $s = setup_dav_site();
    my $a = $s->{auth};
    for my $p ( '/lazysite', '/lazysite/auth/users', '/lazysite/auth/.secret',
                '/lazysite/manager/locks/x' ) {
        my $r = run_dav( $s->{docroot}, 'GET', $p, HTTP_AUTHORIZATION => $a );
        is( $r->{code}, 403, "internal path $p denied" );
    }
    # And writes into it too.
    my $w = run_dav( $s->{docroot}, 'PUT', '/lazysite/auth/users',
        body => "evil", HTTP_AUTHORIZATION => $a );
    is( $w->{code}, 403, 'PUT into lazysite/ denied' );
}

# --- blocked extensions / paths on writes -----------------------------
{
    my $s = setup_dav_site();
    my $a = $s->{auth};

    my $pl = run_dav( $s->{docroot}, 'PUT', '/content/evil.pl',
        body => "code", HTTP_AUTHORIZATION => $a );
    is( $pl->{code}, 403, '.pl write blocked' );

    my $cgi = run_dav( $s->{docroot}, 'PUT', '/content/x.cgi',
        body => "code", HTTP_AUTHORIZATION => $a );
    is( $cgi->{code}, 403, '.cgi write blocked (default blocked_extensions)' );

    # cgi-bin is a default blocked path
    my $cb = run_dav( $s->{docroot}, 'PUT', '/cgi-bin/x.txt',
        body => "x", HTTP_AUTHORIZATION => $a );
    is( $cb->{code}, 403, 'cgi-bin write blocked' );
}

# --- scope confinement -------------------------------------------------
{
    my $s = setup_dav_site( scope => '/content' );
    my $a = $s->{auth};

    my $in = run_dav( $s->{docroot}, 'PUT', '/content/ok.md',
        body => "hi", HTTP_AUTHORIZATION => $a );
    is( $in->{code}, 201, 'write inside scope allowed' );

    my $out = run_dav( $s->{docroot}, 'PUT', '/index.md',
        body => "hi", HTTP_AUTHORIZATION => $a );
    is( $out->{code}, 403, 'write outside scope denied' );

    # Boundary: /content must not match /contentX
    mkdir "$s->{docroot}/contentX";
    my $sib = run_dav( $s->{docroot}, 'PUT', '/contentX/x.md',
        body => "hi", HTTP_AUTHORIZATION => $a );
    is( $sib->{code}, 403, 'sibling prefix /contentX is outside /content scope' );

    # Reads are confined too.
    my $rd = run_dav( $s->{docroot}, 'GET', '/index.md', HTTP_AUTHORIZATION => $a );
    is( $rd->{code}, 403, 'read outside scope denied' );
}

# --- symlink escaping the docroot is rejected -------------------------
SKIP: {
    my $s = setup_dav_site();
    my $a = $s->{auth};
    my $target = "/tmp/lzs-dav-escape-$$";
    open my $tf, '>', $target or skip "cannot create symlink target", 1;
    print $tf "outside\n";
    close $tf;
    symlink( $target, "$s->{docroot}/content/escape" )
        or skip "symlink unsupported", 1;

    my $r = run_dav( $s->{docroot}, 'GET', '/content/escape', HTTP_AUTHORIZATION => $a );
    is( $r->{code}, 403, 'symlink resolving outside docroot is rejected' );
    unlink $target;
}

done_testing();
