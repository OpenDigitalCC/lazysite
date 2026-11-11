#!/usr/bin/perl
#
# SM1439 (ruling 239): A FULL RESTORE GIVES A SITE THAT SERVES.
#
# The SM1438 rehearsal restored a full backup onto a new docroot with
# `install.pl --restore-full`. The content, the auth store and the conf came
# back, and `lazysite check` on the result then reported the three cgi-bin entry
# points missing - the restore extracted the docroot only - and, with no serving
# group applied, a spread of group and mode failures. The restore ended on "Check
# file ownership/permissions on the target host", which left the sysop to finish
# the job by hand.
#
# One command now does it: --restore-full lays the engine's entry points from the
# release it runs (the code --mode provision uses), applies the group and modes as
# provision does, and leaves a site that passes its own check.
#
# The cycle is the operator's: provision a scratch site, take a full backup with
# the manager's own code, DESTROY the site, restore onto a NEW docroot with
# --serving-group, and run the check with that group. Everything lives under the
# test's temp dir.
use strict;
use warnings;
use Test::More;
use File::Copy     ();
use File::Path     qw(make_path remove_tree);
use File::Basename qw(dirname);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_manifest_guard site_tempdir);

my $ROOT    = "$FindBin::Bin/../..";
my $INSTALL = "$ROOT/install.pl";
my $CHECK   = "$ROOT/tools/lazysite-check.pl";
plan skip_all => 'install.pl not found' unless -f $INSTALL;

my $MF_GUARD = repo_manifest_guard();

# The fixture's group, not the web server's: the test user's own group is the one
# group every runner is in.
my $GROUP = getgrgid( $) + 0 ) // ( $) + 0 );

# site_tempdir gives $t/site/public_html; the cgi-bin sits beside it.
my $sa    = site_tempdir();
my $tmp   = dirname( dirname $sa );
my $sa_cg = dirname($sa) . '/cgi-bin';
my $sb    = "$tmp/b/public_html";
my $sb_cg = "$tmp/b/cgi-bin";
my $kept  = "$tmp/kept";
make_path( $sa, $sa_cg, $kept );

sub run {
    my (@cmd) = @_;
    my $r = TestHelper::run_child( \@cmd, stderr => 'merge' );
    return ( $r->{out}, $r->{status} >> 8 );
}

# ---- provision, add content, take a full backup the way the manager does ----
my ( $pout, $prc ) = run( $^X, $INSTALL, '--mode', 'provision', '--docroot', $sa,
    '--cgibin', $sa_cg, '--domain', 'temp.example.com', '--serving-group', $GROUP );
cmp_ok( $prc, '!=', 1, 'the scratch site provisions' ) or diag $pout;

open my $cf, '>', "$sa/canary.md" or die $!;
print {$cf} "---\ntitle: Canary\n---\n\nRESTORE-CANARY\n";
close $cf;

require Lazysite::Manager::Backups;
{
    no warnings 'once';
    $Lazysite::Manager::Backups::DOCROOT      = $sa;
    $Lazysite::Manager::Backups::LAZYSITE_DIR = "$sa/lazysite";
}
my $made = Lazysite::Manager::Backups::action_backup_create('full');
ok( $made->{ok}, 'a full backup is taken' ) or diag explain $made;
my $name = $made->{name} // '';
File::Copy::copy( "$sa/lazysite/backups/$name", "$kept/$name" )
    or BAIL_OUT("cannot copy the backup out: $!");

# ---- destroy the site ----
remove_tree( dirname($sa), { safe => 0 } );
ok( !-d $sa, 'the original site is gone' );

# ---- restore onto a new docroot: one command ----
my ( $rout, $rrc ) = run( $^X, $INSTALL, '--restore-full', "$kept/$name",
    '--docroot',       $sb, '--cgibin', $sb_cg, '--domain', 'www.final.example',
    '--serving-group', $GROUP );

subtest 'the restore succeeds and lays the entry points' => sub {
    is( $rrc, 0, '--restore-full exits 0' ) or diag $rout;
    for my $f (qw(lazysite-processor.pl lazysite-auth.pl lazysite-manager-api.pl)) {
        ok( -f "$sb_cg/$f", "cgi-bin/$f is present" );
    }
    ok( -f "$sb/canary.md", 'the content came back' );
    unlike( $rout, qr/Check file ownership/,
        'and it no longer hands the job back to the sysop' );
};

subtest 'the restored site passes its own check' => sub {
    my ( $cout, $crc ) = run( $^X, $CHECK, '--docroot', $sb, '--cgibin', $sb_cg,
        '--group', $GROUP );
    like( $cout, qr/\b0 failure\(s\)/, 'lazysite check reports 0 failures' )
        or diag $cout;
    is( $crc, 0, 'and exits 0' );
};

subtest 'without the entry points it can lay, it refuses and says what to run' => sub {
    my ( $out, $rc ) = run( $^X, $INSTALL, '--restore-full', "$kept/$name",
        '--docroot', "$tmp/c/public_html", '--domain', 'x.example' );
    isnt( $rc, 0, 'no --cgibin: refused' );
    like( $out, qr/--cgibin/,       'naming the missing option' );
    like( $out, qr/--restore-full/, 'and the command to run' );
    ok( !-d "$tmp/c/public_html/lazysite", 'and nothing was extracted' );
};

subtest 'the install state records what the restore laid' => sub {
    require JSON::PP;
    require Digest::SHA;
    open my $vf, '<', "$ROOT/VERSION" or die $!;
    chomp( my $version = <$vf> );
    close $vf;
    open my $sf, '<', "$sb/lazysite/.install-state.json" or BAIL_OUT("no install state: $!");
    my $state = JSON::PP::decode_json( do { local $/; <$sf> } );
    close $sf;
    is( $state->{version}, $version, 'it records this release, not the backup\'s' );
    for my $f (qw(lazysite-processor.pl lazysite-auth.pl lazysite-manager-api.pl)) {
        my $p = "$sb_cg/$f";
        is( $state->{files}{$p}, 'sha256:' . Digest::SHA->new(256)->addfile($p)->hexdigest,
            "$f is recorded with the hash on disk, so an upgrade does not read it as edited" );
    }

    # An upgrade-mode pass at the same release finds nothing to do and says
    # which version the site is at; a reinstall re-lays it without a refusal.
    my ( $uout, $urc ) = run( $^X, $INSTALL, '--mode', 'upgrade', '--docroot', $sb,
        '--cgibin', $sb_cg, '--serving-group', $GROUP );
    is( $urc, 0, 'upgrade at the same release exits 0' ) or diag $uout;
    like( $uout, qr/already at \Q$version\E/, 'and reports the release\'s version' );
    my ( $rout, $rrc2 ) = run( $^X, $INSTALL, '--mode', 'reinstall', '--docroot', $sb,
        '--cgibin', $sb_cg, '--serving-group', $GROUP );
    isnt( $rrc2, 2, 'reinstall is not refused' ) or diag $rout;
};

done_testing();
