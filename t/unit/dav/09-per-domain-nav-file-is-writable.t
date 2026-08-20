#!/usr/bin/perl
# SM443: a per-domain nav file must be writable by the capability that owns
# navigation.
#
# The carve-out tested `$rel eq 'lazysite/nav.conf'` - an EXACT match on one
# filename. So a domain whose nav_file was set to lazysite/nav-<site>.conf had
# a navigation file that NO surface could populate: nav-save writes the shared
# file, and WebDAV fell through to the blanket lazysite/ denial with "only
# lazysite/layouts/ is writable over WebDAV". domain-set accepted the setting
# regardless, and because layouts guard on [% IF nav.size %], the visible
# result was a site with NO navigation rather than an error.
#
# The widening is bounded by CONFIGURATION, not by pattern alone: a path is
# admitted only if lazysite.conf declares it as somebody's nav_file, and only
# if it has the nav-file shape. That matters because this branch returns
# ALLOWED before the scope, blocklist and ACL gates run - so the shape check in
# read_conf is a boundary, and the cases below exercise it as one.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(run_dav setup_dav_site grant_caps);

my $s = setup_dav_site(
    conf => "webdav_enabled: true\n"
        . "nav_file: lazysite/nav.conf\n"
        . "alias_hosts: xisl.example\n"
        . "alias.xisl.example.nav_file: lazysite/nav-xisl.conf\n"
        . "alias.xisl.example.content_root: sites/xisl\n"
        # Declared with a traversal shape: must NOT be admitted.
        . "alias.evil.example.nav_file: ../../etc/passwd\n"
        # Declared as the privilege-bearing conf: must NOT be admitted.
        . "alias.worse.example.nav_file: lazysite/lazysite.conf\n" );
my $doc  = $s->{docroot};
my $auth = $s->{auth};

grant_caps( $doc, 'deploy', 'manage_nav' );

sub req {
    my ( $m, $p, %opt ) = @_;
    return run_dav( $doc, $m, $p, HTTP_AUTHORIZATION => $auth, %opt );
}
sub wrote { my $c = shift; $c == 201 || $c == 204 }

ok( wrote( req( 'PUT', '/lazysite/nav.conf', body => "Home | /\n" )->{code} ),
    'the default nav file is writable, as it always was' );

ok( wrote( req( 'PUT', '/lazysite/nav-xisl.conf', body => "Home | /\n" )->{code} ),
    'a CONFIGURED per-domain nav file is writable with manage_nav' )
    or diag( 'This is the defect: domain-set accepts a nav_file that no '
        . 'surface can populate, and the site renders with no navigation '
        . 'rather than reporting an error.' );

is( req( 'PUT', '/lazysite/nav-unconfigured.conf', body => "x\n" )->{code}, 403,
    'a nav-SHAPED path nobody configured is still denied' )
    or diag( 'The widening must be bounded by configuration. Admitting any '
        . 'lazysite/*.conf would hand manage_nav the whole directory.' );

is( req( 'PUT', '/lazysite/lazysite.conf', body => "x\n" )->{code}, 403,
    'lazysite.conf stays denied even when declared as a nav_file' )
    or diag( 'It carries privilege-bearing keys. A conf value must not be '
        . 'able to nominate it, or setting nav_file becomes an escalation.' );

is( req( 'PUT', '/lazysite/forms/smtp.conf', body => "x\n" )->{code}, 403,
    'and the forms secrets are untouched by this branch' );

done_testing();
