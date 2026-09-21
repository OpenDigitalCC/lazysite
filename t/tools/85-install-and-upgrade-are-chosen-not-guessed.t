#!/usr/bin/perl
# SM892 U1/U2/D1: install, upgrade and reinstall are CHOSEN by the operator.
#
# THE RULING. Three options were put to the release manager and all three were
# refused, because all three kept install and upgrade as one command that
# decides for itself which it is doing:
#
#   "One place for install, and another for upgrade, because they should be
#    purposefully chosen. Then all docs and scripts refer to the one way to do
#    each."
#
# WHAT IT COST BEFORE. The V3 walk ran the documented command on a RUNNING site
# and was told "Next steps: 1. Create the first account. A fresh install has NO
# accounts". Not a wording defect: one command wearing two hats, choosing the
# wrong one to speak from, because nothing ever told it which the operator
# meant. install.pl read `.install-state.json` and picked fresh / reinstall /
# upgrade on its own.
#
# So the mode is now DECLARED, and the classifier that used to pick it has
# become the thing that CHECKS the declaration - the difference being that a
# mismatch is now an answer to the operator rather than a silent substitution.
#
# THE REFUSAL NAMES THE OTHER COMMAND. An operator who chose wrongly has one
# question - "then what should I have run?" - and the refusal answers it with
# the state it found, because "already installed" without the version is a
# fact they then have to go and look up.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir run_cmd repo_manifest_guard);

my $root = repo_root();
my $cli  = "$root/tools/lazysite-cli.pl";
plan skip_all => "no cli at $cli" unless -f $cli;

# The installer reads the payload's release manifest, which is a gitignored
# BUILD artefact. The guard builds a fresh one and takes it away again - and
# never trusts one that was already lying around, because a stale manifest
# describes a tree that no longer exists.
my $guard = repo_manifest_guard();

# A site pair per case: the CLI refuses to run as root, and these run as the
# invoking user, so the docroot and cgi-bin are ordinary directories here.
sub site {
    my $d = site_tempdir();
    make_path("$d/cgi-bin");
    return ( $d, "$d/cgi-bin" );
}

sub cli {
    my (@args) = @_;
    my $out = run_cmd( $^X, $cli, @args );
    return ( $? >> 8, $out );
}

subtest 'provision makes a site, and says which it did' => sub {
    my ( $d,  $cgi ) = site();
    my ( $rc, $out ) = cli( 'provision', '--docroot', $d, '--cgibin', $cgi );
    is( $rc, 0, 'provision exits 0 on an empty docroot' ) or diag($out);
    ok( -f "$d/lazysite/.install-state.json", 'and the site now has install state' );
};

subtest 'provision REFUSES a site that is already installed' => sub {
    # The first half of the defect: this used to fall through to the installer,
    # which resolved it to reinstall-or-upgrade and proceeded. An operator
    # meaning "set this site up" could move a live site forward and be told
    # afterwards, or not at all.
    my ( $d, $cgi ) = site();
    my ( $rc0, undef ) = cli( 'provision', '--docroot', $d, '--cgibin', $cgi );
    is( $rc0, 0, 'the site is installed first' );

    my ( $rc, $out ) = cli( 'provision', '--docroot', $d, '--cgibin', $cgi );
    isnt( $rc, 0, 'a second provision is refused' )
        or diag("provision exited 0 on an installed site:\n$out");
    like( $out, qr/already installed/i, 'it says the site is already installed' );
    like( $out, qr/\bupgrade\b/,        'and names upgrade' )
        or diag( 'An operator who chose the wrong verb has one question, and '
            . 'the refusal has to answer it.' );
    like( $out, qr/\d+\.\d+\.\d+/, 'and states the version it found' );
};

subtest 'upgrade REFUSES a docroot with nothing installed' => sub {
    # The other half, and the worse one: this used to resolve to `fresh` and
    # silently FRESH-INSTALL. An operator meaning "move this site forward"
    # got a new site, and the only thing that ever stopped them was a missing
    # cgi-bin - not the missing installation.
    my ( $d,  $cgi ) = site();
    my ( $rc, $out ) = cli( 'upgrade', '--docroot', $d, '--cgibin', $cgi );
    isnt( $rc, 0, 'upgrade is refused' )
        or diag("upgrade exited 0 on an empty docroot:\n$out");
    ok( !-f "$d/lazysite/.install-state.json",
        'and NOTHING was installed' )
        or diag( 'A silent fresh install is the failure this refusal exists '
            . 'for: the operator asked to move a site forward.' );
    like( $out, qr/\bprovision\b/, 'it names provision' );
};

subtest 'upgrade on an already-current site is a NO-OP, not a failure' => sub {
    # The distinction the fleet depends on. `lazysite upgrade --all` crosses
    # sites that are already current - most of them, by the end of a rollout -
    # and each of those used to resolve to the inferred `reinstall` and exit 0.
    # Refusing here would turn a 29-site rollout's ordinary no-ops into 29
    # reported failures, so this is the case that must NOT be a refusal.
    my ( $d, $cgi ) = site();
    my ( $rc0, undef ) = cli( 'provision', '--docroot', $d, '--cgibin', $cgi );
    is( $rc0, 0, 'the site is installed first' );

    my ( $rc, $out ) = cli( 'upgrade', '--docroot', $d, '--cgibin', $cgi );
    is( $rc, 0, 'upgrade exits 0 with nothing to do' )
        or diag("a current site must not report failure:\n$out");
    like( $out, qr/nothing to upgrade/i, 'and says there was nothing to do' );
    like( $out, qr/\breinstall\b/,
        'naming reinstall, for an operator who meant to re-lay the files' );
};

subtest 'reinstall is a verb, and it is not upgrade' => sub {
    # SM892 Q4, as ruled: "reinstall (that doesn't affect content) makes sense
    # - upgrade of the same version is confusing. reinstall is distinctly
    # different, could be a verb to fix up a problem without version change."
    my ( $d, $cgi ) = site();
    my ( $rc0, undef ) = cli( 'provision', '--docroot', $d, '--cgibin', $cgi );
    is( $rc0, 0, 'the site is installed first' );

    # Content the operator wrote. A reinstall must not touch it - that is the
    # whole of what distinguishes it from a fresh install.
    open my $fh, '>', "$d/index.md" or die $!;
    print {$fh} "---\ntitle: Mine\n---\n\nMY OWN WORDS\n";
    close $fh;

    my ( $rc, $out ) = cli( 'reinstall', '--docroot', $d, '--cgibin', $cgi );
    is( $rc, 0, 'reinstall exits 0 at the installed version' ) or diag($out);

    open my $in, '<', "$d/index.md" or die $!;
    my $kept = do { local $/; <$in> };
    close $in;
    like( $kept, qr/MY OWN WORDS/, "the operator's content is untouched" )
        or diag( 'A reinstall that overwrites content is a fresh install '
            . 'wearing the wrong name.' );
};

subtest 'reinstall REFUSES when the version differs - that is upgrade' => sub {
    # The declaration has to be checked in BOTH directions, or "chosen" only
    # means "chosen when the choice happened to be right".
    my ( $d, $cgi ) = site();
    my ( $rc0, undef ) = cli( 'provision', '--docroot', $d, '--cgibin', $cgi );
    is( $rc0, 0, 'the site is installed first' );

    # Backdate the recorded version, so the payload is now newer - which is
    # exactly an upgrade, and exactly what reinstall must not silently do.
    my $sp = "$d/lazysite/.install-state.json";
    open my $r, '<', $sp or die $!;
    my $j = do { local $/; <$r> };
    close $r;
    $j =~ s/"version"\s*:\s*"[^"]+"/"version":"0.0.1"/;
    open my $w, '>', $sp or die $!;
    print {$w} $j;
    close $w;

    my ( $rc, $out ) = cli( 'reinstall', '--docroot', $d, '--cgibin', $cgi );
    isnt( $rc, 0, 'reinstall is refused' ) or diag($out);
    like( $out, qr/\bupgrade\b/, 'and names upgrade' );
    like( $out, qr/0\.0\.1/,     'stating the version it found' );
};

done_testing();
