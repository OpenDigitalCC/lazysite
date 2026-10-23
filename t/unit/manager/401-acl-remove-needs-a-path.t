#!/usr/bin/perl
# SM1270 (ruling 17, 2026-10-23): acl-remove with no path is refused.
#
# The control API's dispatcher defaults path to '/', and '' is one of SM287's
# spellings of the root, so acl-remove with no path - or an empty one - removed
# the site-wide rule and published everything it held back. SM306 kept that
# default as the easy way to recover a site; the ruling replaces it, and the
# site-wide rule is removed with '/' typed out.
#
# This is the handler half, Files::action_acl_remove, which the control API,
# the CLI and MCP's remove_permissions all call. The dispatcher half is
# t/integration/52, through the real CGI.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Manager::Files qw(action_acl_set action_acl_remove);
use Lazysite::Auth::Acl      qw(load_acls);

my $d = site_tempdir();
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;

$Lazysite::Manager::Files::DOCROOT  = $d;
$Lazysite::Manager::Common::DOCROOT = $d;
$Lazysite::Auth::Acl::DOCROOT       = $d;
$Lazysite::Auth::Acl::auth_user     = 'alice';

sub root_rule { return load_acls()->{'/'} }

my $set = action_acl_set( '/', 'alice', ['alice'], undef, undef, undef );
ok( $set->{ok}, 'a site-wide rule is set' ) or diag( $set->{error} // '' );

for my $case ( [ undef, 'no path' ], [ '', 'an empty path' ] ) {
    my ( $path, $label ) = @$case;
    my $r = action_acl_remove( $path, 'alice' );
    ok( !$r->{ok}, "$label is refused" );
    is( $r->{kind},  'missing-parameter', "$label: kind missing-parameter" );
    is( $r->{field}, 'path',              "$label: the field is path" );
    like( $r->{error} // '', qr{path=/}, "$label: the message names path=/" );
    like( $r->{error} // '', qr/whole site/, "$label: and says what path=/ removes" );
    ok( root_rule(), "$label: the site-wide rule is still in place" );
}

# Typed, the root still comes off - in each spelling SM287 normalises, so a
# rule written as one of them can always be removed.
for my $spelling ( '/', '.', './' ) {
    action_acl_set( '/', 'alice', ['alice'], undef, undef, undef );
    my $r = action_acl_remove( $spelling, 'alice' );
    ok( $r->{ok}, "'$spelling' removes the site-wide rule" ) or diag( $r->{error} // '' );
    is( $r->{removed}, 1, "'$spelling': removed 1" );
    ok( !root_rule(), "'$spelling': and the rule is gone" );
}

done_testing();
