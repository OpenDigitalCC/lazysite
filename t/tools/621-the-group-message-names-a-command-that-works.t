#!/usr/bin/perl
#
# n807 / SM1427: THE INSTALLER'S GROUP MESSAGE NAMES A COMMAND THAT CAN WORK.
#
# When an install cannot give the paths it created the docroot's group (the user
# is not in that group), the summary said "run the install as the site owner, or
# root". The OWNER run is the one that fails, and `provision` refuses root, so the
# advice sent the release manager (2026-11-10) round a loop on a new Hestia site:
# 424 paths without the web group, 14 checks failing, the site answering 500.
#
# The way out is one of two root commands, and the message names them:
#   - lazysite-hestia-deploy.sh USER DOMAIN, on a Hestia host (the whole install
#     and the repair in one);
#   - lazysite-cli.pl repair --docroot D, anywhere.
#
# THE FIXTURE: a docroot whose group the invoker cannot chown to. `unshare -r`
# maps the caller to root in a new user namespace where the caller's other group
# is unmapped, so chown into it fails exactly as it does for a site user outside
# www-data. Without a supplementary group, or without user namespaces, there is
# nothing to fail on and the test skips.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(site_tempdir);

my $ROOT    = "$FindBin::Bin/../..";
my $INSTALL = "$ROOT/install.pl";
plan skip_all => 'install.pl not found' unless -f $INSTALL;

my @gids    = split ' ', $);
my $primary = $gids[0];
my ($second) = grep { $_ != $primary } @gids[ 1 .. $#gids ];
plan skip_all => 'needs a supplementary group to fail the chown on'
    unless defined $second;
plan skip_all => 'no unprivileged user namespaces on this host'
    unless system('unshare -r --map-root-user true >/dev/null 2>&1') == 0;

my $docroot = site_tempdir();
my $cgibin  = dirname($docroot) . '/cgi-bin';
make_path($cgibin);
chown -1, $second, $docroot or plan skip_all => "cannot chgrp the docroot: $!";
chmod 0755, $docroot;

my $out = `unshare -r --map-root-user $^X \Q$INSTALL\E --mode provision --docroot \Q$docroot\E --cgibin \Q$cgibin\E 2>&1`;

like( $out, qr/created path\(s\) could not be given group/,
    'the fixture reaches the message (a group the installer cannot give)' )
    or diag $out;

unlike( $out, qr/run the install as the\s+site owner/,
    'it no longer sends the reader to the owner run, which is the one that fails' );
like( $out, qr/lazysite-hestia-deploy\.sh USER DOMAIN/,
    'it names the Hestia deploy, which does the install and the repair as root' );
like( $out, qr/lazysite-cli\.pl repair --docroot \Q$docroot\E/,
    'and the root repair for any other host, with this docroot in it' );

done_testing();
