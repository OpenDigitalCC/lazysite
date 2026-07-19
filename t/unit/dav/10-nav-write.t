#!/usr/bin/perl
# SM072 / 0.8.1 cross-plane consistency: lazysite/nav.conf is agent-editable over
# WebDAV when the account holds `manage_nav` - the SAME capability the control-API
# (nav-save) and MCP (set_nav) require, and the one Capabilities.pm documents as
# owning nav.conf. (Before 0.8.1 WebDAV used the coarser manage_config here; this
# realigns it.) manage_config alone no longer grants nav over WebDAV. lazysite.conf
# and the rest of lazysite/ stay denied.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(run_dav setup_dav_site dav_users_tool grant_caps revoke_caps);

my $s    = setup_dav_site( conf => "webdav_enabled: true\n", caps => ['webdav'] );
my $doc  = $s->{docroot};
my $auth = $s->{auth};

# --- without manage_nav: nav.conf write is denied ---------------------
{
    my $r = run_dav( $doc, 'PUT', '/lazysite/nav.conf',
        HTTP_AUTHORIZATION => $auth, body => "Home | /\n" );
    is( $r->{code}, 403, 'nav.conf write denied without manage_nav' );
}

# --- manage_config alone does NOT grant nav (the realignment) ---------
grant_caps( $doc, 'deploy', 'manage_config' );
{
    my $r = run_dav( $doc, 'PUT', '/lazysite/nav.conf',
        HTTP_AUTHORIZATION => $auth, body => "Home | /\n" );
    is( $r->{code}, 403,
        'nav.conf write still denied with only manage_config (WebDAV now matches API/MCP: nav = manage_nav)' );
}

grant_caps( $doc, 'deploy', 'manage_nav' );

# --- with manage_nav: write and read nav.conf -------------------------
{
    my $r = run_dav( $doc, 'PUT', '/lazysite/nav.conf',
        HTTP_AUTHORIZATION => $auth, body => "Home | /\nDocs | /docs\n" );
    ok( $r->{code} == 201 || $r->{code} == 204, 'nav.conf write allowed with manage_nav' );
    ok( -s "$doc/lazysite/nav.conf", 'nav.conf written to disk' );

    my $p = run_dav( $doc, 'PROPFIND', '/lazysite/nav.conf',
        HTTP_AUTHORIZATION => $auth, HTTP_DEPTH => '0' );
    is( $p->{code}, 207, 'nav.conf PROPFIND ok' );
}

# --- lazysite.conf stays denied even with these caps ------------------
{
    my $r = run_dav( $doc, 'PUT', '/lazysite/lazysite.conf',
        HTTP_AUTHORIZATION => $auth, body => "plugins: evil\n" );
    is( $r->{code}, 403, 'lazysite.conf write stays denied' );
}

done_testing();
