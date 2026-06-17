#!/usr/bin/perl
# SM070: conditional requests (If-Match / If-None-Match) and the
# interaction of the If lock-token header with write methods.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_dav_site run_dav);

my $LOCKBODY = '<?xml version="1.0"?><D:lockinfo xmlns:D="DAV:">'
    . '<D:lockscope><D:exclusive/></D:lockscope>'
    . '<D:locktype><D:write/></D:locktype></D:lockinfo>';

sub etag_of {
    my ( $s, $rel ) = @_;
    my $r = run_dav( $s->{docroot}, 'PROPFIND', $rel, HTTP_DEPTH => '0', HTTP_AUTHORIZATION => $s->{auth} );
    my ($e) = $r->{body} =~ m{<D:getetag>(".*?")</D:getetag>};
    return $e;
}

# --- If-Match -----------------------------------------------------------
{
    my $s = setup_dav_site();
    run_dav( $s->{docroot}, 'PUT', '/content/p.md', body => "v1", HTTP_AUTHORIZATION => $s->{auth} );
    my $etag = etag_of( $s, '/content/p.md' );
    ok( $etag, 'got an etag' );

    my $good = run_dav( $s->{docroot}, 'PUT', '/content/p.md',
        body => "v2", HTTP_IF_MATCH => $etag, HTTP_AUTHORIZATION => $s->{auth} );
    is( $good->{code}, 204, 'If-Match on current etag => proceed' );

    my $stale = run_dav( $s->{docroot}, 'PUT', '/content/p.md',
        body => "v3", HTTP_IF_MATCH => '"deadbeef-0-0-0"', HTTP_AUTHORIZATION => $s->{auth} );
    is( $stale->{code}, 412, 'If-Match on a stale etag => 412' );
}

# --- If-None-Match: * (create-only) -----------------------------------
{
    my $s = setup_dav_site();
    my $create = run_dav( $s->{docroot}, 'PUT', '/content/new.md',
        body => "x", HTTP_IF_NONE_MATCH => '*', HTTP_AUTHORIZATION => $s->{auth} );
    is( $create->{code}, 201, 'If-None-Match:* on a new path => 201' );

    my $clash = run_dav( $s->{docroot}, 'PUT', '/content/new.md',
        body => "y", HTTP_IF_NONE_MATCH => '*', HTTP_AUTHORIZATION => $s->{auth} );
    is( $clash->{code}, 412, 'If-None-Match:* on an existing path => 412' );
}

# --- If lock-token enforcement on writes ------------------------------
{
    my $s = setup_dav_site();
    run_dav( $s->{docroot}, 'PUT', '/content/p.md', body => "x", HTTP_AUTHORIZATION => $s->{auth} );
    my $lr = run_dav( $s->{docroot}, 'LOCK', '/content/p.md', body => $LOCKBODY, HTTP_AUTHORIZATION => $s->{auth} );
    my ($tok) = ( $lr->{headers}{'lock-token'} // '' ) =~ /<([^>]+)>/;

    my $no = run_dav( $s->{docroot}, 'PUT', '/content/p.md', body => "y", HTTP_AUTHORIZATION => $s->{auth} );
    is( $no->{code}, 423, 'write to locked resource without the token => 423' );

    # Untagged If list form
    my $untag = run_dav( $s->{docroot}, 'PUT', '/content/p.md',
        body => "y", HTTP_IF => "(<$tok>)", HTTP_AUTHORIZATION => $s->{auth} );
    is( $untag->{code}, 204, 'untagged If token unlocks the write' );

    # Tagged If list form
    my $tag = run_dav( $s->{docroot}, 'PUT', '/content/p.md',
        body => "z", HTTP_IF => "</dav/content/p.md> (<$tok>)", HTTP_AUTHORIZATION => $s->{auth} );
    is( $tag->{code}, 204, 'tagged If token also unlocks the write' );
}

# --- manager-origin lock cannot be overridden from DAV ----------------
{
    my $s = setup_dav_site();
    run_dav( $s->{docroot}, 'PUT', '/content/p.md', body => "x", HTTP_AUTHORIZATION => $s->{auth} );
    # Simulate a manager editor lock (legacy line format, origin=manager).
    my $ld = "$s->{docroot}/lazysite/manager/locks";
    mkdir "$s->{docroot}/lazysite/manager"; mkdir $ld;
    open my $fh, '>', "$ld/content:p.md.lock" or die;
    print $fh "alice " . time();    # legacy manager lock
    close $fh;

    my $blocked = run_dav( $s->{docroot}, 'PUT', '/content/p.md',
        body => "y", HTTP_IF => "(<opaquelocktoken:anything>)", HTTP_AUTHORIZATION => $s->{auth} );
    is( $blocked->{code}, 423, 'manager-origin lock blocks DAV writes regardless of If' );
}

done_testing();
