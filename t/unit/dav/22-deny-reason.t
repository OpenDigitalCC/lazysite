#!/usr/bin/perl
# RI-002: a WebDAV denial must tell a partner (typically an agent) WHY the write
# was refused - which capability is missing or which rule applies - so it can fix
# the request instead of retrying blindly. The reported pain was theme install:
# a content partner's PUT under lazysite/layouts/ returned a bare "Forbidden".
#
# Each refused write now carries the reason in the body ("Forbidden: <reason>")
# and a machine-parseable X-Lazysite-Deny-Reason header. These tests pin the
# reason text (loosely, on the capability name) AND that authorisation itself is
# unchanged: an allowed write still succeeds and carries no deny header.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_dav_site run_dav);

sub deny_hdr { $_[0]->{headers}{'x-lazysite-deny-reason'} }

# --- A content partner (no manage_themes/layouts) installing a theme --------
{
    my $s = setup_dav_site();    # default caps: webdav, manage_content, nav, forms
    my $r = run_dav( $s->{docroot}, 'PUT',
        '/lazysite/layouts/base/themes/mytheme/theme.css',
        HTTP_AUTHORIZATION => $s->{auth}, body => "body{}\n" );

    is( $r->{code}, 403, 'theme install without the capability is refused' );
    like( $r->{body}, qr/manage_themes/,
        'body names the missing manage_themes capability (the reported case)' );
    like( deny_hdr($r), qr/manage_themes|manage_layouts/,
        'X-Lazysite-Deny-Reason header carries the machine-parseable reason' );
    isnt( $r->{body}, "Forbidden\n", 'no longer a bare Forbidden' );
}

# --- A webdav-only account (no manage_content) publishing content -----------
{
    my $s = setup_dav_site( caps => ['webdav'] );
    my $r = run_dav( $s->{docroot}, 'PUT', '/content/page.md',
        HTTP_AUTHORIZATION => $s->{auth}, body => "hi\n" );

    is( $r->{code}, 403, 'content write without manage_content is refused' );
    like( $r->{body}, qr/manage_content/, 'reason names manage_content' );
}

# The active layout/theme pointers live under the conf keys `layout:`/`theme:`.
my $ACTIVE_CONF = "webdav_enabled: true\nlayout: base\ntheme: live\n";

# --- A themes partner editing the ACTIVE theme (read-only over DAV) ---------
{
    my $s = setup_dav_site(
        caps => [qw(webdav manage_themes)],
        conf => $ACTIVE_CONF,
    );
    my $r = run_dav( $s->{docroot}, 'PUT',
        '/lazysite/layouts/base/themes/live/theme.css',
        HTTP_AUTHORIZATION => $s->{auth}, body => "body{}\n" );

    is( $r->{code}, 403, 'writing the active theme over DAV is refused' );
    like( $r->{body}, qr/active theme.*read-only|read-only.*active/i,
        'reason explains the active-theme read-only rule' );
}

# --- Happy path: a themes partner installing a NON-active theme is allowed --
# authorise() returns undef, so the request reaches the PUT handler (which may
# then 409 on a missing parent collection) - the point is NOT a 403 and NO
# deny-reason header, proving the change is to messaging only, not authorisation.
{
    my $s = setup_dav_site(
        caps => [qw(webdav manage_themes)],
        conf => $ACTIVE_CONF,
    );
    my $r = run_dav( $s->{docroot}, 'PUT',
        '/lazysite/layouts/base/themes/fresh/theme.css',
        HTTP_AUTHORIZATION => $s->{auth}, body => "body{}\n" );

    isnt( $r->{code}, 403, "non-active theme write is not refused (got $r->{code}) - authorisation unchanged" );
    is( deny_hdr($r), undef, 'a permitted write carries no deny-reason header' );
}

done_testing();
