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

# SM899. The 0.14.3 W1 transcript, run by the operator from an unpacked
# tarball: every refusal above was correct and every one of them told them to
# type `lazysite upgrade ...` - a command that answers "command not found" on
# that host - and then ended with "command failed (exit 2): /usr/bin/perl
# .../install.pl --docroot ... --mode provision". Their first question was
# where `lazysite` existed; their reading of the last line was that they had
# run something wrong.
subtest 'a refusal spells the command the way this one was reached' => sub {
    # This test reaches the CLI as `perl /abs/path/tools/lazysite-cli.pl`,
    # which is the tarball shape. The hint has to be typeable on this host.
    my ( $d, $cgi ) = site();
    my ( $rc0, undef ) = cli( 'provision', '--docroot', $d, '--cgibin', $cgi );
    is( $rc0, 0, 'the site is installed first' );

    my ( $rc, $out ) = cli( 'provision', '--docroot', $d, '--cgibin', $cgi );
    isnt( $rc, 0, 'a second provision is refused' );
    like( $out, qr/perl \Q$cli\E upgrade --docroot/,
        'the hint is `perl <this cli> upgrade ...`' )
        or diag("operator asked: where does the command `lazysite` exist?\n$out");
    unlike( $out, qr/\blazysite upgrade\b/,
        'and not `lazysite upgrade`, which this host does not have' );
};

subtest 'reached as `lazysite`, the hint says `lazysite`' => sub {
    # The deb shape: /usr/bin/lazysite. Any link by that name is the same
    # case - what matters is what the operator typed, which is $0's basename.
    my ( $d, $cgi ) = site();
    my $bin = site_tempdir();
    symlink( $cli, "$bin/lazysite" ) or plan skip_all => "cannot symlink: $!";

    my $out0 = run_cmd( $^X, "$bin/lazysite", 'provision', '--docroot', $d, '--cgibin', $cgi );
    is( $? >> 8, 0, 'the site is installed through the link' ) or diag($out0);
    my $out = run_cmd( $^X, "$bin/lazysite", 'provision', '--docroot', $d, '--cgibin', $cgi );
    isnt( $? >> 8, 0, 'a second provision is refused' );
    like( $out, qr/^\s+To move it to \S+:\s+lazysite upgrade --docroot/m,
        'the hint is `lazysite upgrade ...`' )
        or diag($out);
};

subtest 'a refusal by design ends with the refusal, and keeps its exit code' => sub {
    my ( $d, $cgi ) = site();
    my ( $rc0, undef ) = cli( 'provision', '--docroot', $d, '--cgibin', $cgi );
    is( $rc0, 0, 'the site is installed first' );

    my ( $rc, $out ) = cli( 'provision', '--docroot', $d, '--cgibin', $cgi );
    is( $rc, 2, "the installer's refusal code (2) is what the operator gets" )
        or diag("exit $rc:\n$out");
    unlike( $out, qr/command failed/,
        'nothing says a command failed - a refusal is not a failed command' )
        or diag($out);
    unlike( $out, qr/install\.pl/,
        'and nothing points at install.pl, which the operator never typed' )
        or diag($out);
    like( $out, qr/ALREADY INSTALLED/, 'the refusal itself is still there' );
};

subtest 'a crash is still reported as one' => sub {
    # The discriminator: run_installer forwards ONLY the two by-design codes.
    # An installer that dies still gets run_or_fail's line, so a real failure
    # is not mistaken for a quiet refusal.
    #
    # A `die` exits with $! when it is set - so the first draft's uncreatable
    # docroot under /proc died with ENOENT, which is 2, and read as a refusal.
    # A parent the caller may not write into dies with EACCES (13) instead.
    plan skip_all => 'root ignores directory modes' if $> == 0;
    my ( undef, $cgi ) = site();
    my $parent = site_tempdir();
    chmod 0555, $parent or die $!;
    my ( $rc, $out ) = cli( 'provision', '--docroot', "$parent/site", '--cgibin', $cgi );
    chmod 0755, $parent;
    isnt( $rc, 0, 'it fails' );
    isnt( $rc, 2, 'and not with the refusal code' ) or diag($out);
    like( $out, qr/command failed \(exit \d+\)/,
        'run_or_fail reports it as a failed command, naming the exit' )
        or diag($out);
};

subtest '--installdir stands for both paths' => sub {
    # The operator's ask: "it would be easier to just specify installdir which
    # can then assume the docroot and cgi paths." On HestiaCP the pair is
    # always DIR/public_html and DIR/cgi-bin.
    my $dir = site_tempdir();
    make_path("$dir/public_html");    # provision needs the docroot's parent to exist
    my ( $rc, $out ) = cli( 'provision', '--installdir', $dir );
    is( $rc, 0, 'provision --installdir DIR exits 0' ) or diag($out);
    ok( -f "$dir/public_html/lazysite/.install-state.json",
        'the site landed at DIR/public_html' );
    ok( -d "$dir/cgi-bin", 'and the cgi-bin at DIR/cgi-bin' );

    my ( $rc2, $out2 ) = cli( 'reinstall', '--installdir', $dir );
    is( $rc2, 0, 'reinstall --installdir DIR finds the same site' ) or diag($out2);

    # Two statements of one path is how a wrong one goes unnoticed.
    my ( $rc3, $out3 ) = cli( 'upgrade', '--installdir', $dir, '--docroot', "$dir/public_html" );
    is( $rc3, 2, '--installdir with --docroot is a usage error' ) or diag($out3);
    unlike( $out3, qr/command failed|install\.pl/, 'refused by the CLI, before any site was touched' );
};

done_testing();
