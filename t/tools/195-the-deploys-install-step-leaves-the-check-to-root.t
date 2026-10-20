#!/usr/bin/perl
# SM1220 (#356): THE FOUR "could not read ... Permission denied" WARNINGS ON EVERY
# HESTIA DEPLOY CAME FROM INSTALL.PL'S OWN HEALTH CHECK, RUN AS THE SITE USER.
#
# The deploy runs as root and its FINAL check (`lazysite-check.pl ... --fix`, after
# the permission pass) already runs as root, so it reads the private store the web
# server group owns. install.pl, run by the deploy as the site user (sudo -u),
# ends with a check of its own; as ispadmin that check cannot open
# <docroot>-lazysite-private/sites, and its Q16g report - four WARN lines, each
# containing "Permission denied" - reached the batch updater's findings report on
# every site. The ruling: the read-only checks run as root, no group change.
#
# So the deploy tells install.pl not to run that interim check (--health-check-by-caller);
# the root check is the deploy's one verdict (SM1205). Pinned here:
#   1. install.pl --health-check-by-caller runs no check, and says so in words;
#   2. without it install.pl still checks (the standalone install is unchanged);
#   3. the deploy passes the flag on its install call, and no check of any kind
#      runs through `sudo -u` in the deploy.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root repo_manifest_guard site_tempdir);

my $root    = repo_root();
my $install = "$root/install.pl";
my $deploy  = "$root/installers/hestia/lazysite-hestia-deploy.sh";
plan skip_all => 'install.pl or the Hestia deploy is not here' unless -f $install && -f $deploy;

sub slurp { open my $f, '<', $_[0] or die "$_[0]: $!"; local $/; my $t = <$f>; close $f; $t }
sub spit { my ( $p, $t ) = @_; open my $f, '>', $p or die "$p: $!"; print {$f} $t; close $f; chmod 0755, $p }

my $guard = repo_manifest_guard();
my $group = getgrgid( $) + 0 ) // ( $) + 0 );

my $docroot = site_tempdir();
my $cgibin  = "$docroot/../cgi-bin";
make_path($cgibin);

my $out = `$^X \Q$install\E --mode provision --docroot \Q$docroot\E --cgibin \Q$cgibin\E --serving-group \Q$group\E --health-check-by-caller 2>&1`;
is( $? >> 8, 0, 'install.pl --health-check-by-caller installs and exits 0' ) or diag $out;
unlike( $out, qr/=== Health check ===/, 'and runs no health check' );
like( $out, qr/^Health check: not run here/m, 'and says it was not run, so silence is not read as healthy' );
unlike( $out, qr/^\s*(?:WARN|FAIL)\b|Permission denied/m, 'and prints no finding' );

my $site2 = site_tempdir();
my $cgi2  = "$site2/../cgi-bin";
make_path($cgi2);
my $plain = `$^X \Q$install\E --mode provision --docroot \Q$site2\E --cgibin \Q$cgi2\E --serving-group \Q$group\E 2>&1`;
like( $plain, qr/=== Health check ===/, 'without the flag install.pl still runs its check' );

# --- the deploy ---------------------------------------------------------------
my $d = slurp($deploy);
my ($call) = $d =~ /^(sudo -u "\$U" perl "\$STAGE\/install\.pl" --mode "\$MODE"[^\n]*)$/m;
ok( $call, 'found the deploy\'s install call' ) or BAIL_OUT('the deploy changed shape');
like( $call, qr/--health-check-by-caller/, 'the deploy\'s install call leaves the check to its own root pass' );

my $dir = site_tempdir();
( my $t = $dir ) =~ s{/site/public_html\z}{};
mkdir "$t/bin";
spit( "$t/bin/sudo", "#!/bin/bash\necho \"sudo \$*\" >> '$t/log'\n" );
spit( "$t/run.sh", "#!/bin/bash\nU=u; STAGE=/stage; MODE=upgrade; DOC=/d; CGI=/c\nPATH='$t/bin':\$PATH\n$call\n" );
system("bash '$t/run.sh' >/dev/null 2>&1");
like( slurp("$t/log"), qr/--mode upgrade .*--health-check-by-caller/, 'run with a stand-in sudo, the flag reaches install.pl' );

my @as_user = grep { /\bsudo\b/ && /lazysite-check|lazysite check/ } split /\n/, $d;
is( scalar @as_user, 0, 'no check runs through sudo -u in the deploy: every check is root\'s' )
    or diag join "\n", @as_user;
like( $d, qr/^perl "\$DOM\/tools\/lazysite-check\.pl" --docroot "\$DOC" --cgibin "\$CGI" --fix$/m,
    'the deploy\'s one check runs as the deploy does (root)' );

done_testing();
