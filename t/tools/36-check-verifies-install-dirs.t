#!/usr/bin/perl
# SM268 03-F7: `check` verifies the WHOLE declared model, not eleven paths of it.
#
# SM246 states the design as "one table, three consumers - install applies,
# check verifies, check --fix repairs". That was true of runtime_paths and false
# of install_dirs: lazysite-check.pl carried its own hand-written list of eleven
# lazysite/* directories while the model declared twenty-eight. The consequence
# is the one that matters: a site already carrying the reported fault - the
# docroot's content directories stripped of group write, which is the 0.6.5
# incident SM246 exists for - stayed broken, and this tool called it healthy.
# make_declared_path applies a mode ON CREATION and never corrects an existing
# directory, so the fix was prospective only and nothing in the tree said so.
#
# Reported, not repaired. These are content directories on a live site, and an
# operator who tightened one deliberately should not have it widened by a tool
# they ran to ask a question. --fix stays on the CGI writability set, where the
# mode is a functional requirement rather than a default.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP   ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_manifest_guard);

my $ROOT     = "$FindBin::Bin/../..";
my $INSTALL  = "$ROOT/install.pl";
my $CHECK    = "$ROOT/tools/lazysite-check.pl";
my $BUILD_MF = "$ROOT/tools/build-manifest.pl";

plan skip_all => 'install.pl not found'        unless -f $INSTALL;
plan skip_all => 'lazysite-check.pl not found' unless -f $CHECK;

# SM269 phase 1: this test needs release-manifest.json AT THE REPO ROOT, and so
# do two others. Under `prove -j` they raced - one deleted at END what another
# was still using. The guard serialises just these three.
my $MF_GUARD = repo_manifest_guard();

my $REPO_MF = "$ROOT/release-manifest.json";
my $MF_OURS = 0;
unless ( -f $REPO_MF ) {
    system( $^X, $BUILD_MF ) == 0 or BAIL_OUT('failed to build release-manifest.json');
    $MF_OURS = 1;
}
END { unlink $REPO_MF if $MF_OURS && -f $REPO_MF }

my $base    = tempdir( 'lazysite-checkdirs-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
my $docroot = "$base/site";
my $cgibin  = "$base/cgi-bin";
make_path( $docroot, $cgibin );

my $out = `$^X \Q$INSTALL\E --docroot \Q$docroot\E --cgibin \Q$cgibin\E 2>&1`;
is( $? >> 8, 0, 'install exited 0' ) or BAIL_OUT($out);

subtest 'the install records the resolved directory modes' => sub {
    my $state = "$docroot/lazysite/.install-state.json";
    ok( -f $state, 'the install state exists' ) or return;
    open my $fh, '<', $state or die $!;
    my $j = JSON::PP::decode_json( do { local $/; <$fh> } );
    close $fh;
    ok( ref $j->{dirs} eq 'HASH', 'it carries a dirs map' );
    cmp_ok( scalar keys %{ $j->{dirs} || {} }, '>=', 20,
        'covering the model, not a hand-written subset - the subset was the '
            . 'defect' );
};

# The reported incident: group write stripped from a docroot content directory.
my ($victim) = grep { -d "$docroot/$_" } qw(docs manager lazysite/templates);
plan skip_all => 'no content directory to test against' unless $victim;
chmod 02755, "$docroot/$victim";

subtest 'check reports a content directory that lost its declared mode' => sub {
    my $report = `$^X \Q$CHECK\E --docroot \Q$docroot\E 2>&1`;
    like( $report, qr/\Q$victim\E is 2755, the model declares 2775/,
        'the fault is named, with both modes' );
    like( $report, qr/chmod 2775/, 'and the repair is one paste away' );
};

subtest 'and does not repair it' => sub {
    my $report = `$^X \Q$CHECK\E --docroot \Q$docroot\E --fix 2>&1`;
    my $mode   = ( stat "$docroot/$victim" )[2] & 07777;
    is( $mode, 02755,
        '--fix leaves a content directory alone: an operator who tightened one '
            . 'on purpose must not have it widened by a tool they ran to ask a '
            . 'question' );
    like( $report, qr/\Q$victim\E/, 'though it still says so' );
};

subtest 'a correct directory is not reported' => sub {
    chmod 02775, "$docroot/$victim";
    my $report = `$^X \Q$CHECK\E --docroot \Q$docroot\E 2>&1`;
    unlike( $report, qr/\Q$victim\E is \d+, the model declares/,
        'a check that reported every directory would pass the subtest above '
            . 'for the wrong reason' );
    like( $report, qr/declared directories carry their declared mode/,
        'and it says positively that the model was verified' );
};

# --- SM270: the docroot itself ----------------------------------------------
#
# From a live 0.10.5 upgrade. Hestia's v-rebuild-web-domain resets public_html
# to its own default (2751: setgid, NO group write), the operator followed the
# release notes' instruction to re-render vhosts for the SM268 H17 PT fix, and
# this tool reported the site healthy while the manager could not save a file.
#
# SM268 03-F7 had excluded the docroot from the model check along with the
# parent and the cgi-bin, reasoning that those are pre-existing and the
# platform's business. That was right about two of the three: the docroot's mode
# is a functional requirement, because the CGI writes every authoring surface
# through it.
subtest 'a docroot the CGI cannot write is a FAIL, and --fix repairs it' => sub {
    chmod 02751, $docroot;
    my $report = `$^X \Q$CHECK\E --docroot \Q$docroot\E 2>&1`;
    like( $report, qr/docroot is 2751 and is NOT group-writable/,
        'reported, with the mode' );
    like( $report, qr/SM270/, 'and pointed at the rebuild that causes it' );

    `$^X \Q$CHECK\E --docroot \Q$docroot\E --fix 2>&1`;
    my $mode = ( stat $docroot )[2] & 07777;
    is( $mode, 02775,
        '--fix repairs it - unlike the content directories, this one is "the '
            . 'site does not work" rather than "someone may have tightened it '
            . 'on purpose"' );
};

subtest 'writable-but-no-setgid is a warning, not a failure' => sub {
    chmod 00775, $docroot;
    my $report = `$^X \Q$CHECK\E --docroot \Q$docroot\E 2>&1`;
    like( $report, qr/warn.*docroot is 0775 - writable, but without setgid/,
        'the slower-burning problem is reported as the lesser one' );
    unlike( $report, qr/FAIL.*docroot is 0775/,
        'and NOT as a failure - a hand-made dev docroot is 0775, and a check '
            . 'that fails on every one of those teaches its reader to skip the '
            . 'line that matters' );
    chmod 02775, $docroot;
};

done_testing();
