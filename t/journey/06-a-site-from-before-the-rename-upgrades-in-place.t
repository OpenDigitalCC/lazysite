#!/usr/bin/perl
# Journey (SM1142 S4): A SITE FROM BEFORE THE RENAME UPGRADES IN PLACE AND BEHAVES THE SAME.
#
# The filing's one journey: a site as 0.16.3 left it - its extensions in the old
# directory beside the docroot, the old list header and old-directory entries in
# lazysite.conf (the login rate limiter, the data tables and the persistent
# runtime among them), an edited copy of a shipped extension and the two cgi-bin
# links the installer makes - is upgraded in place by the current installer.
#
# t/tools/306 checks what the upgrade step WROTE. This asks the engine's own
# readers what they now SEE, each the one that decides on a live site: the sign-in
# CGI's rate-limit switch, the manager's data gate, the runtime's start gate, the
# notifier's transport switch and the render path's unit registry and manager nav.
# Every one must answer as it did before the upgrade. A reader the rename missed
# answers "off" here, silently, which is the failure the filing exists to prevent.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_manifest_guard repo_root load_processor);
use PreRenameSite qw(new_site install make_pre_rename slurp spit);

my $MF_GUARD = repo_manifest_guard();
my $ROOT     = repo_root();

my ( $docroot, $cgibin, $root ) = new_site();
my ( $rc, $out ) = install( $docroot, $cgibin, 'provision' );
is( $rc, 0, 'the site is provisioned' ) or diag $out;
make_pre_rename( $docroot, $cgibin, $root, qw(data.pl daemon.pl form-smtp.pl stats.pl) );

# The edited copy: a shipped extension changed by hand in the old directory.
opendir my $dh, $root or die $!;
my ($old) = grep { -d "$root/$_" && $_ ne 'extensions' && -f "$root/$_/stats.pl" } readdir $dh;
closedir $dh;
ok( defined $old, 'the fixture has its extensions in the old directory' ) or BAIL_OUT('no fixture');
spit( "$root/$old/stats.pl", slurp("$root/$old/stats.pl") . "\n# the site's own note\n" );

( $rc, $out ) = install( $docroot, $cgibin, 'upgrade' );
is( $rc, 0, 'the site upgrades in place' ) or diag $out;

# --- the readers ------------------------------------------------------------
require Lazysite::Auth::LoginRate;
ok( Lazysite::Auth::LoginRate::_rate_limit_switched_on($docroot),
    'the sign-in CGI still counts attempts: login rate limiting is on' );

require Lazysite::Manager::Data;
{
    no warnings 'once';
    local $Lazysite::Manager::Data::DOCROOT       = $docroot;
    local $Lazysite::Manager::Extensions::DOCROOT = $docroot;
    ok( Lazysite::Manager::Extensions::extension_enabled('extensions/data.pl'),
        'the data tables are still on' );
}

require Lazysite::Daemon::Supervisor;
ok( Lazysite::Daemon::Supervisor::should_run($docroot), 'the persistent runtime may still start' );

require Lazysite::Notify;
ok( Lazysite::Notify::_extension_enabled( $docroot, 'form-smtp.pl' ),
    'the notifier still sends through the SMTP extension' );
ok( !Lazysite::Notify::_extension_enabled( $docroot, 'notify-xmpp.pl' ),
    'and one that was off is still off' );

load_processor($docroot);
main::_reset_units();
ok( main::_unit_enabled('extensions/data.pl'), 'the render path still serves data rows' );
ok( main::_unit_enabled('extensions/login-rate-limit.pl'), 'and reads the rate limiter as on' );
my $nav = main::_enabled_extensions();
ok( $nav->{stats} && $nav->{data}, 'the manager nav still shows Stats and Data tables' );

# --- the tree ---------------------------------------------------------------
ok( !-e "$root/$old", 'no old directory is left' );
# old-name: begin (SM1142, the name the upgrade gives an edited copy)
like( slurp("$root/extensions/stats.pl.from-plugins") // '', qr/# the site's own note/,
    'the edited copy moved beside the release\'s' );
# old-name: end
for my $l (qw(form-handler.pl payment-demo.pl)) {
    ok( -f "$cgibin/$l" && readlink("$cgibin/$l") =~ m{/extensions/\Q$l\E\z},
        "the cgi-bin link $l works and points into extensions/" );
}
my $describe = `\Q$^X\E -I\Q$ROOT/lib\E \Q$cgibin/form-handler.pl\E --describe 2>/dev/null`;
like( $describe, qr/"id"\s*:\s*"form-handler"/, 'and the form handler answers through it' );

done_testing();
