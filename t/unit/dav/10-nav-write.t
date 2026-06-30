#!/usr/bin/perl
# SM072: lazysite/nav.conf is agent-editable over WebDAV when the account
# holds manage_config. lazysite.conf and the rest of lazysite/ stay denied.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(run_dav setup_dav_site dav_users_tool grant_caps revoke_caps);

my $s    = setup_dav_site( conf => "webdav_enabled: true\n" );
my $doc  = $s->{docroot};
my $auth = $s->{auth};

# --- without manage_config: nav.conf write is denied ------------------
{
    my $r = run_dav( $doc, 'PUT', '/lazysite/nav.conf',
        HTTP_AUTHORIZATION => $auth, body => "Home | /\n" );
    is( $r->{code}, 403, 'nav.conf write denied without manage_config' );
}

grant_caps( $doc, 'deploy', 'manage_config' );

# --- with manage_config: write and read nav.conf ----------------------
{
    my $r = run_dav( $doc, 'PUT', '/lazysite/nav.conf',
        HTTP_AUTHORIZATION => $auth, body => "Home | /\nDocs | /docs\n" );
    ok( $r->{code} == 201 || $r->{code} == 204, 'nav.conf write allowed with manage_config' );
    ok( -s "$doc/lazysite/nav.conf", 'nav.conf written to disk' );

    my $p = run_dav( $doc, 'PROPFIND', '/lazysite/nav.conf',
        HTTP_AUTHORIZATION => $auth, HTTP_DEPTH => '0' );
    is( $p->{code}, 207, 'nav.conf PROPFIND ok' );
}

# --- lazysite.conf stays denied even with manage_config ---------------
{
    my $r = run_dav( $doc, 'PUT', '/lazysite/lazysite.conf',
        HTTP_AUTHORIZATION => $auth, body => "plugins: evil\n" );
    is( $r->{code}, 403, 'lazysite.conf write stays denied' );
}

done_testing();
