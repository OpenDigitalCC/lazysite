#!/usr/bin/perl
# SM070: end-to-end publishing - a DAV write becomes a served page, a
# re-write updates it (cache invalidated), a delete unpublishes it.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use MIME::Base64 qw(encode_base64);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_dav run_processor setup_minimal_site dav_users_tool);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);
make_path("$docroot/lazysite/auth");

# Enable WebDAV and create a webdav-capable user.
open my $cf, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
print $cf "webdav_enabled: true\n";
close $cf;
dav_users_tool( $docroot, 'add', 'deploy', 'secret' );
dav_users_tool( $docroot, 'set', 'deploy', 'webdav', 'on' );
my $auth = 'Basic ' . encode_base64( 'deploy:secret', '' );

# --- PUT publishes a page ---------------------------------------------
{
    my $put = run_dav( $docroot, 'PUT', '/published.md',
        body => "---\ntitle: Published\n---\nFIRST-VERSION\n",
        HTTP_AUTHORIZATION => $auth );
    is( $put->{code}, 201, 'PUT new page => 201' );

    my $out = run_processor( $docroot, '/published' );
    like( $out, qr/Status:\s*200/, 'processor serves the published page' );
    like( $out, qr/FIRST-VERSION/, 'page content rendered' );
}

# --- re-PUT updates it, cache invalidated -----------------------------
{
    # prime the rendered cache
    run_processor( $docroot, '/published' );
    my $put = run_dav( $docroot, 'PUT', '/published.md',
        body => "---\ntitle: Published\n---\nSECOND-VERSION\n",
        HTTP_AUTHORIZATION => $auth );
    is( $put->{code}, 204, 're-PUT => 204' );

    my $out = run_processor( $docroot, '/published' );
    like( $out, qr/SECOND-VERSION/, 'updated content served (cache dropped)' );
    unlike( $out, qr/FIRST-VERSION/, 'stale content gone' );
}

# --- DELETE unpublishes ------------------------------------------------
{
    my $del = run_dav( $docroot, 'DELETE', '/published.md', HTTP_AUTHORIZATION => $auth );
    is( $del->{code}, 204, 'DELETE => 204' );

    my $out = run_processor( $docroot, '/published' );
    like( $out, qr/Status:\s*404/, 'deleted page now 404s' );
}

done_testing();
