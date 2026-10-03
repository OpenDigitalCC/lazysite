#!/usr/bin/perl
#
# SM939 E2 / R15: A FRESH INSTALL CAN LEAVE LAZYSITE'S OWN CONTENT OFF THE SITE.
#
# A fresh install puts the demo pages and ~70 pages of /docs on the owner's
# domain, publicly served and in the sitemap from the first minute. Right for a
# site that IS lazysite's documentation; someone else's content on anybody else's,
# and removing it afterwards is seventy-odd deletes to undo something the install
# did on purpose. The ruling keeps today's default and adds an opt-out.
#
# WHAT THIS PINS, AND WHY EACH HALF:
#
#   1. --no-starter leaves the demo pages and /docs out, and KEEPS the pages a
#      site genuinely needs (forgot, logout - and assets/, .well-known/, which
#      were never starter content). An opt-out that removed the login pages
#      would ship a broken site instead of an empty one.
#   2. THE CHOICE SURVIVES AN UPGRADE WITHOUT THE FLAG. docs/ is bucket `code`,
#      so on an upgrade every untracked docs file is planned as a fresh install;
#      without the recorded choice the opt-out would last exactly until the
#      first upgrade. This is the half a test of the provision alone would miss.
#   3. The default is unchanged: no flag, the starter content arrives as before.
#      R15 ruled the default stays, and a change here would alter every new site.
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use JSON::PP       qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_manifest_guard site_tempdir);

my $ROOT    = "$FindBin::Bin/../..";
my $INSTALL = "$ROOT/install.pl";
plan skip_all => 'install.pl not found' unless -f $INSTALL;

my $MF_GUARD = repo_manifest_guard();
my $GROUP    = getgrgid( $) + 0 ) // ( $) + 0 );

sub fixture {
    my $d = site_tempdir();
    make_path( dirname($d) . '/cgi-bin' );
    return $d;
}

sub install {
    my ( $docroot, $mode, @extra ) = @_;
    my $cgibin = dirname($docroot) . '/cgi-bin';
    my $out = `$^X \Q$INSTALL\E --mode \Q$mode\E --docroot \Q$docroot\E \\
        --cgibin \Q$cgibin\E --serving-group \Q$GROUP\E @extra 2>&1`;
    return ( $out, $? >> 8 );
}

sub state_of {
    my ($docroot) = @_;
    my $f = "$docroot/lazysite/.install-state.json";    # install.pl state_path
    return {} unless -f $f;
    open my $fh, '<', $f or return {};
    local $/;
    return eval { decode_json(<$fh>) } || {};
}

my $bare = fixture();
my ( $out, $rc ) = install( $bare, 'provision', '--no-starter' );
is( $rc, 0, 'provision --no-starter succeeded and passed its health check' )
    or diag $out;

subtest 'the starter content is left out' => sub {
    ok( !-e "$bare/docs",               'no /docs tree' );
    ok( !-e "$bare/lazysite-demo.md",   'no demo page' );
    ok( !-e "$bare/payment-demo.md",    'no payment demo' );
    ok( !-e "$bare/members.md",         'no members demo' );
    ok( !-e "$bare/contact.md",         'no contact demo' );
    like( $out, qr/Starter:\s+not installed \((\d+) file/,
        'and the summary says so, so an empty site reads as a choice' );
    my ($n) = $out =~ /not installed \((\d+) file/;
    cmp_ok( $n // 0, '>', 30, "with a count ($n) - docs alone is over thirty files" );
};

subtest 'what a site needs is still there' => sub {
    ok( -f "$bare/forgot.md", 'the password reset page' )
        or diag( 'An opt-out that removed it would ship a broken site, not an '
            . 'empty one: the login flow links to it.' );
    ok( -f "$bare/logout.md",                   'the logout page' );
    ok( -d "$bare/assets",                      'assets/' );
    ok( -d "$bare/.well-known",                 '.well-known/' );
    ok( -d "$bare/manager",                     'the manager' );
    ok( -f "$bare/lazysite/lazysite.conf.example", 'the conf example' );
};

subtest 'the choice is recorded, and a later run honours it without the flag' => sub {
    my $st = state_of($bare);
    is( $st->{starter}, 'none', 'the install state records starter: none' )
        or diag explain [ keys %$st ];

    # REINSTALL, not upgrade. The first version of this file used `upgrade
    # --force`, and a sabotage that stopped the state being READ still passed:
    # an upgrade to the version already installed is a no-op ("nothing to
    # upgrade"), so it never planned a file. Reinstall re-lays the whole payload
    # against the existing state, which is exactly the run that would ship the
    # docs if the recorded choice were ignored.
    my ( $out2, $rc2 ) = install( $bare, 'reinstall' );
    cmp_ok( $rc2, '!=', 1, 'the reinstall ran' ) or diag $out2;
    like( $out2, qr/Install summary/, 'and actually laid files' )
        or diag( 'A run that stops before planning proves nothing here.' );
    ok( !-e "$bare/docs", 'and STILL no /docs tree' )
        or diag( 'docs/ is bucket code: a re-lay plans every untracked docs '
            . 'file as a fresh install. Without the recorded choice the opt-out '
            . 'lasts exactly until the first upgrade.' );
    is( state_of($bare)->{starter}, 'none', 'and the choice is still recorded' );
};

subtest 'the default is unchanged' => sub {
    my $full = fixture();
    my ( $o3, $rc3 ) = install( $full, 'provision' );
    is( $rc3, 0, 'a plain provision succeeded' ) or diag $o3;
    ok( -d "$full/docs",             'it ships /docs' );
    ok( -f "$full/lazysite-demo.md", 'and the demo page' );
    unlike( $o3, qr/Starter:/, 'and says nothing about starter content' );
    ok( !exists state_of($full)->{starter}, 'and records no opt-out' );
};

done_testing();
