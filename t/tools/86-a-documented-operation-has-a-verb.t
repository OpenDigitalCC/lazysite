#!/usr/bin/perl
# SM892 D5: the operations the documentation tells an operator to perform are
# reachable through the `lazysite` CLI, and behave as the documentation says.
#
# WHY THIS FILE EXISTS AT ALL. D4 turned install.sh into a signpost that refuses
# everything. That broke four blocks of live advice in starter/docs/install.md
# and UPGRADE.md - listing backups, restoring one, previewing an upgrade,
# restoring a full-system backup - and the choice at that point was between
# naming install.pl in an operator document, which D3 says stop doing, and
# giving each operation a word. Reaching past the CLI to the implementation is
# how the CLI becomes the second-best way to do things, and a second-best way is
# a second spelling.
#
# Two more came with it: `channel` and `policy`, which four documents told the
# operator to set by running install.pl - and which install.pl's own comment
# suggested applying to a fleet with a shell loop over docroots, "because
# lazysite has no central site registry". It has had one since SM139.
#
# WHAT IS ASSERTED. Behaviour, not source: each verb is driven for real against
# a temp site and the result read off the filesystem. t/lint/149 holds the
# documents to these verbs; this file holds the verbs to what the documents say.
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

my $guard = repo_manifest_guard();

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

sub installed {
    my ($d) = @_;
    my $p = "$d/lazysite/.install-state.json";
    return 0 unless -f $p;
    open my $fh, '<', $p or return 0;
    my $j = do { local $/; <$fh> };
    close $fh;
    return $j =~ /"version"/ ? 1 : 0;
}

sub conf {
    my ($d) = @_;
    my $p = "$d/lazysite/lazysite.conf";
    return '' unless -f $p;
    open my $fh, '<', $p or return '';
    my $t = do { local $/; <$fh> };
    close $fh;
    return $t;
}

subtest '--dry-run writes NOTHING - not even the registry entry' => sub {
    # "Preview looks like apply" is the failure class this whole filing is
    # about, so the preview has to be a real one. The thing that makes this
    # worth a test rather than a comment is the registry: `provision` records
    # the site in /etc/lazysite/sites.d/ AFTER the installer returns, and a
    # preview that leaves a registry entry behind has told the fleet a site
    # exists that was never installed.
    my ( $d, $cgi ) = site();
    my ( $rc, $out ) = cli( 'provision', '--docroot', $d, '--cgibin', $cgi, '--dry-run' );
    is( $rc, 0, 'provision --dry-run exits 0' ) or diag($out);
    ok( !installed($d), 'nothing was installed' )
        or diag( 'starter/docs/install.md says --dry-run "reports what would '
            . 'change and writes nothing at all".' );
    like( $out, qr/nothing was written/i,
        'and it says so, rather than leaving the reader to infer it' );
    like( $out, qr/no registry entry/i, 'naming the registry specifically' );
};

subtest 'a preview does not tell the operator to restart anything' => sub {
    # The restart line is the one this filing put in `upgrade`. On a preview
    # nothing was replaced, so nothing is holding the previous engine - and a
    # reminder that fires when it does not apply is one people learn to skip,
    # which is how the runbook's own restart line came to be ignored for four
    # releases (N141-05, N142A, SM892: three placements, one ignored line).
    #
    # THIS IS A SOURCE CHECK, AND THE REASON IS WORTH STATING. Driven for real
    # here it proves nothing: _say_what_needs_restarting returns immediately
    # unless the docroot is a REGISTERED site with a live systemd unit, and a
    # temp docroot in a test is neither - so the line is absent whether or not
    # the guard exists, and an `unlike` on the output would pass by measuring
    # the absence of systemd. (The first draft of this subtest did exactly
    # that, and a sabotage confirmed it: removing the guard changed nothing.)
    #
    # t/tools/78 hit the same wall for the same call and settled it the same
    # way. The honest limit: if the guard were moved behind a condition that is
    # never true, this would still pass.
    my $src = do {
        open my $fh, '<', $cli or die $!;
        local $/;
        <$fh>;
    };
    my @calls = ( $src =~ /_say_what_needs_restarting\(\$docroot\)([^;]*);/g );
    cmp_ok( scalar @calls, '>=', 2, 'both single-site verbs call the restart notice' )
        or diag( 'upgrade and reinstall replace the same files for the same '
            . 'reason - a worker holding engine code does not care which verb '
            . 'put the new code on disk.' );
    for my $tail (@calls) {
        like( $tail, qr/unless \$o\{dry_run\}/,
            'and each is guarded on it not being a preview' );
    }

    # What CAN be driven: the preview still exits 0 and installs nothing.
    my ( $d, $cgi ) = site();
    my ( $rc0, undef ) = cli( 'provision', '--docroot', $d, '--cgibin', $cgi );
    is( $rc0, 0, 'the site is installed first' );
    my ( $rc, $out ) = cli( 'upgrade', '--docroot', $d, '--cgibin', $cgi, '--dry-run' );
    is( $rc, 0, 'upgrade --dry-run exits 0' ) or diag($out);
};

subtest '--dry-run refuses to combine with --all' => sub {
    # Across a fleet it would print 26 plans and change nothing, which reads as
    # a completed rollout to anybody skimming the output.
    my ( $rc, $out ) = cli( 'upgrade', '--all', '--dry-run' );
    isnt( $rc, 0, 'refused' ) or diag($out);
    like( $out, qr/single-site/i, 'and says why' );
};

subtest 'backups: listed, and put back' => sub {
    my ( $d, $cgi ) = site();
    my ( $rc0, undef ) = cli( 'provision', '--docroot', $d, '--cgibin', $cgi );
    is( $rc0, 0, 'the site is installed' );

    my ( $rc1, $out1 ) = cli( 'backups', '--docroot', $d );
    is( $rc1, 0, 'backups exits 0 with none taken yet' ) or diag($out1);
    like( $out1, qr/no backups/i, 'and says there are none' )
        or diag( 'An empty list printed as nothing at all is indistinguishable '
            . 'from a command that failed silently.' );

    # A reinstall takes one, which is what gives the restore something to find.
    my ( $rc2, $out2 ) = cli( 'reinstall', '--docroot', $d, '--cgibin', $cgi );
    is( $rc2, 0, 'reinstall exits 0' ) or diag($out2);

    my ( $rc3, $out3 ) = cli( 'backups', '--docroot', $d );
    is( $rc3, 0, 'backups exits 0' ) or diag($out3);
    like( $out3, qr/\.tar\.gz/, 'and now lists a tarball' )
        or diag( "starter/docs/install.md sends the operator here after a bad "
            . "upgrade. If the list is empty the page is wrong.\n$out3" );

    # Break a code file, then put it back from the backup. Restoring is the
    # half that is worth driving for real: a listing that works and a restore
    # that does not is the shape an operator meets at the worst moment.
    my $proc = "$cgi/lazysite-processor.pl";
    ok( -f $proc, 'a code file to damage' );
    open my $w, '>', $proc or die $!;
    print {$w} "BROKEN\n";
    close $w;

    my ( $rc4, $out4 ) = cli( 'backups', '--docroot', $d, '--restore' );
    is( $rc4, 0, 'backups --restore exits 0' ) or diag($out4);

    open my $r, '<', $proc or die $!;
    my $now = do { local $/; <$r> };
    close $r;
    unlike( $now, qr/^BROKEN/, 'the damaged file was restored' );
};

subtest 'backups refuses argument combinations that cannot mean anything' => sub {
    # feedback_missing_parameter_named_as_missing: a flag that names a tarball
    # to restore, with no restore asked for, is a request the command cannot
    # carry out. Accepting it and listing instead would report success for work
    # nobody asked for.
    my ( $d, $cgi ) = site();
    my ( $rc1, $out1 ) = cli( 'backups', '--docroot', $d, '--backup', '/nope.tar.gz' );
    isnt( $rc1, 0, '--backup without --restore is refused' ) or diag($out1);
    like( $out1, qr/--restore/, 'naming what it needs' );

    my ( $rc2, $out2 ) = cli( 'backups', '--docroot', $d,
        '--restore-full', '/nope.tar.gz', '--restore' );
    isnt( $rc2, 0, '--restore-full with --restore is refused' ) or diag($out2);

    my ( $rc3, $out3 ) = cli( 'backups', '--docroot', $d, '--domain', 'x.example' );
    isnt( $rc3, 0, '--domain with nothing to rewrite is refused' ) or diag($out3);

    my ( $rc4, $out4 ) = cli('backups');
    isnt( $rc4, 0, 'and it needs a site' ) or diag($out4);
    like( $out4, qr/--docroot/, 'naming the option' );
};

subtest 'channel and policy are verbs, and they write the conf' => sub {
    my ( $d, $cgi ) = site();
    my ( $rc0, undef ) = cli( 'provision', '--docroot', $d, '--cgibin', $cgi );
    is( $rc0, 0, 'the site is installed' );

    my ( $rc1, $out1 ) = cli( 'channel', 'stable', '--docroot', $d );
    is( $rc1, 0, 'channel exits 0' ) or diag($out1);
    like( conf($d), qr/^update_channel:\s*stable$/m, 'update_channel is set' );

    my ( $rc2, $out2 ) = cli( 'policy', 'auto', '--docroot', $d );
    is( $rc2, 0, 'policy exits 0' ) or diag($out2);
    like( conf($d), qr/^update_policy:\s*auto$/m, 'update_policy is set' );
};

subtest 'an unrecognised channel is refused, not resolved' => sub {
    # SM356 is the reason this is asserted here and not left to the installer:
    # `update_channel: stabel` once meant the MOST permissive setting, silently,
    # and an edge rollout reached customer sites. The installer's default now
    # falls to `stable`, but a verb that accepts the typo and writes it has
    # simply moved the same defect one layer out - the operator typed a word
    # they believed in and the file does not contain it.
    my ( $d, $cgi ) = site();
    my ( $rc0, undef ) = cli( 'provision', '--docroot', $d, '--cgibin', $cgi );
    is( $rc0, 0, 'the site is installed' );

    my ( $rc, $out ) = cli( 'channel', 'stabel', '--docroot', $d );

    # THE EXIT CODE CANNOT SETTLE THIS, and finding that out is what this
    # comment is for. install.pl ALSO refuses the value, with exit 2 - but
    # run_or_fail collapses any non-zero child into the CLI's own exit 1, so
    # `isnt($rc, 0)` and even `is($rc, 1)` pass whether or not the CLI checks
    # anything. Two sabotages confirmed it.
    #
    # What does discriminate is whether a child ran at all: run_or_fail's
    # failure reads "command failed (exit 2): ...". Its ABSENCE is the evidence
    # that the value was refused BEFORE any site was touched - which is what
    # matters for `--all`, where the alternative is one typo attempted against
    # twenty-six sites in turn, each reporting its own failure, and nothing
    # saying the word was never valid in the first place.
    isnt( $rc, 0, 'refused' ) or diag($out);
    unlike( $out, qr/command failed/,
        'and refused by the CLI, without reaching a site' )
        or diag( "This output is run_or_fail reporting a child's exit status, "
            . "which means the value was passed through to the installer "
            . "rather than checked here.\n$out" );
    like( $out, qr/edge/, 'and the refusal lists the words that work' );
    unlike( conf($d), qr/stabel/, 'and nothing was written' );

    my ( $rc2, $out2 ) = cli( 'policy', 'automatic', '--docroot', $d );
    isnt( $rc2, 0, 'the same for policy' ) or diag($out2);
    unlike( $out2, qr/command failed/, 'also without reaching a site' );
};

subtest 'channel with no value points at the verb that READS it' => sub {
    # A setter invoked with nothing to set is most often somebody trying to find
    # out what the current setting is. `lazysite sites` is that, per site, for
    # the whole fleet - and saying so costs one sentence.
    my ( $d, $cgi ) = site();
    my ( $rc, $out ) = cli( 'channel', '--docroot', $d );
    isnt( $rc, 0, 'refused' ) or diag($out);
    like( $out, qr/lazysite sites/, 'naming the verb that reports the setting' );
};

subtest 'channel needs a site, and says which ways there are to name one' => sub {
    my ( $rc, $out ) = cli( 'channel', 'stable' );
    isnt( $rc, 0, 'refused with no target' ) or diag($out);
    like( $out, qr/--docroot/, 'naming --docroot' );
    like( $out, qr/--all/,     'and the fleet form the docs now promise' );
};

done_testing();
