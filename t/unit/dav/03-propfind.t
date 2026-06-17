#!/usr/bin/perl
# SM070: PROPFIND and PROPPATCH.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_dav_site run_dav);

sub seed {
    my ($s) = @_;
    run_dav( $s->{docroot}, 'PUT', '/content/page.md', body => "# Hi\n", HTTP_AUTHORIZATION => $s->{auth} );
    run_dav( $s->{docroot}, 'PUT', '/content/a&b.md', body => "x", HTTP_AUTHORIZATION => $s->{auth} );
    run_dav( $s->{docroot}, 'MKCOL', '/content/sub', HTTP_AUTHORIZATION => $s->{auth} );
}

# --- depth 0 on a file -------------------------------------------------
{
    my $s = setup_dav_site();
    seed($s);
    my $r = run_dav( $s->{docroot}, 'PROPFIND', '/content/page.md',
        HTTP_DEPTH => '0', HTTP_AUTHORIZATION => $s->{auth} );
    is( $r->{code}, 207, 'depth 0 file => 207' );
    like( $r->{body}, qr/<D:multistatus/, 'multistatus body' );
    like( $r->{body}, qr/<D:getcontentlength>5</, 'content length present' );
    like( $r->{body}, qr/<D:getetag>"/, 'etag present' );
    like( $r->{body}, qr/<D:getlastmodified>/, 'last-modified present' );
    like( $r->{body}, qr{<D:supportedlock>.*<D:exclusive/>.*</D:supportedlock>}s,
        'supportedlock advertises exclusive write' );
    unlike( $r->{body}, qr/<D:shared/, 'shared lock not advertised' );
    like( $r->{body}, qr{<D:lockdiscovery/>}, 'empty lockdiscovery when unlocked' );
}

# --- depth 1 listing ---------------------------------------------------
{
    my $s = setup_dav_site();
    seed($s);
    my $r = run_dav( $s->{docroot}, 'PROPFIND', '/content',
        HTTP_DEPTH => '1', HTTP_AUTHORIZATION => $s->{auth} );
    is( $r->{code}, 207, 'depth 1 collection => 207' );
    like( $r->{body}, qr{/dav/content/page\.md}, 'lists page.md' );
    like( $r->{body}, qr{/dav/content/sub/}, 'lists sub collection with trailing slash' );
    # Awkward name is URL-encoded in href and XML-escaped.
    like( $r->{body}, qr{/dav/content/a%26b\.md}, 'ampersand name percent-encoded in href' );
    like( $r->{body}, qr/<D:collection/, 'collection resourcetype present for dir' );
}

# --- depth infinity refused -------------------------------------------
{
    my $s = setup_dav_site();
    seed($s);
    my $r = run_dav( $s->{docroot}, 'PROPFIND', '/content',
        HTTP_DEPTH => 'infinity', HTTP_AUTHORIZATION => $s->{auth} );
    is( $r->{code}, 403, 'depth infinity => 403' );
}

# --- missing target ----------------------------------------------------
{
    my $s = setup_dav_site();
    my $r = run_dav( $s->{docroot}, 'PROPFIND', '/content/nope.md',
        HTTP_DEPTH => '0', HTTP_AUTHORIZATION => $s->{auth} );
    is( $r->{code}, 404, 'missing resource => 404' );
}

# --- missing Depth defaults to 1 --------------------------------------
{
    my $s = setup_dav_site();
    seed($s);
    my $r = run_dav( $s->{docroot}, 'PROPFIND', '/content',
        HTTP_AUTHORIZATION => $s->{auth} );    # no Depth header
    is( $r->{code}, 207, 'absent Depth still yields 207' );
    like( $r->{body}, qr{/dav/content/page\.md}, 'default depth lists children' );
}

# --- PROPPATCH refused per-property -----------------------------------
{
    my $s = setup_dav_site();
    seed($s);
    my $body = '<?xml version="1.0"?><D:propertyupdate xmlns:D="DAV:">'
             . '<D:set><D:prop><Z:x xmlns:Z="z:">1</Z:x></D:prop></D:set>'
             . '</D:propertyupdate>';
    my $r = run_dav( $s->{docroot}, 'PROPPATCH', '/content/page.md',
        body => $body, HTTP_AUTHORIZATION => $s->{auth} );
    is( $r->{code}, 207, 'PROPPATCH => 207 multistatus' );
    like( $r->{body}, qr/403 Forbidden/, 'property write refused with 403' );
}

done_testing();
