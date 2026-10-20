#!/usr/bin/perl
# SM1118 (ruled 2026-10-20, #338): WEBDAV IS A MACHINE DOOR, AND A SITE IN
# MAINTENANCE REFUSES IT TO AN ACCOUNT WITHOUT `maintenance_access`.
#
# A verified account without it is a 503 with Retry-After - every method, OPTIONS
# included, because a client that can still list the tree is not being refused.
# An account that holds it is served exactly as before. A wrong password is still
# the 401 it was (the credential is asked first; a refusal for maintenance must
# not tell a stranger which passwords are right). Off, nobody is refused; per
# domain, the Host decides.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use MIME::Base64 ();
use TestHelper   qw(setup_dav_site run_dav grant_caps dav_users_tool);

my $site = setup_dav_site( conf => "webdav_enabled: true\nmaintenance: on\n" );
my $d    = $site->{docroot};
open my $pg, '>', "$d/content/hello.md" or die $!;
print {$pg} "---\ntitle: Hello\n---\nHello\n";
close $pg;

# `deploy` (the fixture's account) publishes content and does not hold
# maintenance_access; `night` is the same and does.
dav_users_tool( $d, 'add', 'night', 'night-secret-long-enough' );
grant_caps( $d, 'night', qw(webdav manage_content manage_nav manage_forms maintenance_access) );
my %auth = (
    deploy => $site->{auth},
    night => 'Basic ' . MIME::Base64::encode_base64( 'night:night-secret-long-enough', '' ),
    wrong => 'Basic ' . MIME::Base64::encode_base64( 'deploy:not-the-password', '' ),
);

sub dav {
    my ( $who, $method, $path, %o ) = @_;
    return run_dav( $d, $method, $path, HTTP_AUTHORIZATION => $auth{$who}, HTTP_HOST => 'site.test', %o );
}
sub refused {
    my ( $name, $r ) = @_;
    is( $r->{code}, 503, "$name: 503" );
    like( $r->{headers}{'retry-after'} // '', qr/\A\d+\z/, "$name: Retry-After" );
    like( $r->{body}, qr/in maintenance/i, "$name: the maintenance message" );
}
sub served {
    my ( $name, $r ) = @_;
    isnt( $r->{code}, 503, "$name: not a 503" );
    return $r;
}
sub conf_write { my ($t) = @_; open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!; print {$cf} $t; close $cf }

subtest 'an account without the capability is refused every method' => sub {
    refused( 'PROPFIND', dav( 'deploy', 'PROPFIND', '/', HTTP_DEPTH => 1 ) );
    refused( 'GET',      dav( 'deploy', 'GET',      '/content/hello.md' ) );
    refused( 'OPTIONS',  dav( 'deploy', 'OPTIONS',  '/' ) );
    my $r = dav( 'deploy', 'PUT', '/content/new.md', body => "---\ntitle: N\n---\nN\n" );
    refused( 'PUT', $r );
    ok( !-e "$d/content/new.md", '...and the PUT wrote nothing' );
    $r = dav( 'deploy', 'DELETE', '/content/hello.md' );
    refused( 'DELETE', $r );
    ok( -e "$d/content/hello.md", '...and the DELETE removed nothing' );
};

subtest 'an account with it is served as always' => sub {
    my $r = served( 'PROPFIND', dav( 'night', 'PROPFIND', '/', HTTP_DEPTH => 1 ) );
    is( $r->{code}, 207, '...a multistatus' );
    $r = served( 'GET', dav( 'night', 'GET', '/content/hello.md' ) );
    is( $r->{code}, 200, '...the file' );
    $r = served( 'PUT', dav( 'night', 'PUT', '/content/new.md', body => "---\ntitle: N\n---\nN\n" ) );
    ok( -e "$d/content/new.md", '...and the write landed' );
};

subtest 'the credential is asked first' => sub {
    my $r = dav( 'wrong', 'PROPFIND', '/', HTTP_DEPTH => 1 );
    is( $r->{code}, 401, 'a wrong password is a 401, not a 503' );
    $r = run_dav( $d, 'PROPFIND', '/', HTTP_HOST => 'site.test' );
    is( $r->{code}, 401, 'and so is no credential' );
};

subtest 'maintenance off: nobody is refused' => sub {
    conf_write("webdav_enabled: true\nmaintenance: off\n");
    served( 'deploy', dav( 'deploy', 'PROPFIND', '/', HTTP_DEPTH => 1 ) );
    conf_write("webdav_enabled: true\n");
    served( 'deploy, no key', dav( 'deploy', 'PROPFIND', '/', HTTP_DEPTH => 1 ) );
};

subtest 'per domain' => sub {
    conf_write("webdav_enabled: true\nalias_hosts: a.example, b.example\nalias.a.example.maintenance: on\n");
    refused( 'deploy on the domain in maintenance', dav( 'deploy', 'PROPFIND', '/', HTTP_DEPTH => 1, HTTP_HOST => 'a.example' ) );
    served( 'deploy on its sibling', dav( 'deploy', 'PROPFIND', '/', HTTP_DEPTH => 1, HTTP_HOST => 'b.example' ) );
    served( 'night on the domain in maintenance', dav( 'night', 'PROPFIND', '/', HTTP_DEPTH => 1, HTTP_HOST => 'a.example' ) );
    conf_write("webdav_enabled: true\nalias_hosts: a.example, b.example\nmaintenance: on\n");
    refused( 'deploy once the instance switch is on', dav( 'deploy', 'PROPFIND', '/', HTTP_DEPTH => 1, HTTP_HOST => 'b.example' ) );
};

done_testing;
