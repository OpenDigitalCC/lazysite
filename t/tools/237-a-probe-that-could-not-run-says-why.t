#!/usr/bin/perl
# SM1237: a probe that could not run says WHY, per site, and the rollout reports
# the reasons grouped like any other finding.
#
# THE 0.16.0 ROLLOUT (2026-10-22, 32 sites) ended "probe: 16 clean, 0 exposed,
# 16 could not run" and nowhere said why. `lazysite probe` reads the check's
# "ACL PROBE SKIPPED: <cause>" when there is one; when there was not - the probe
# reached the fetch and got nothing back, or the check did not run at all - it
# printed a guess ("usually a docroot or ACL store the probe could not write:
# run lazysite repair"). The rollout read only the exit status.
#
# And the defect behind many such skips: on Hestia the private store's parent is
# the domain folder, mode 0551, so a site that never protected anything has no
# store and the probe - protecting a throwaway folder as the site user - cannot
# create one. Its reason was the generic "IS IN FORCE ... see the warnings",
# with the warnings never printed.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use Cwd ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $root = repo_root();
my $CLI  = "$root/tools/lazysite-cli.pl";
my $UPD  = "$root/installers/hestia/lazysite-hestia-update-all.sh";
# Each site's docroot is <name>/public_html under this, a level down (t/lint/118).
my $T    = Cwd::realpath( site_tempdir() );

sub spit  { my ( $p, $b ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $b; close $fh; return }
sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; my $s = <$fh>; close $fh; return $s }

# A Hestia-shaped site: <dom>/public_html, with one account (so the probe names
# a real principal, SM912), and no private store.
sub a_site {
    my ($name) = @_;
    my $doc = "$T/$name/public_html";
    make_path( "$doc/lazysite/auth", "$doc/lazysite/logs" );
    spit( "$doc/lazysite/lazysite.conf", "site_name: T\n" );
    spit( "$doc/lazysite/auth/users",    "alice:x\n" );
    return $doc;
}

sub probe {
    my (@names) = @_;
    my $reg = "$T/registry";
    make_path($reg);
    unlink glob "$reg/*";
    spit( "$reg/$_", "docroot=$T/$_/public_html\n" ) for @names;
    local $ENV{LAZYSITE_REGISTRY_DIR} = $reg;
    my $out = qx($^X \Q$CLI\E probe --all 2>&1);
    return ( $? >> 8, $out );
}

subtest 'the CLI names a reason for every site it could not confirm' => sub {
    plan skip_all => 'running as root - the probe declines' if $> == 0;
    a_site('locked');
    a_site('open');
    chmod 0551, "$T/locked";    # the Hestia domain root

    my ( $rc, $out ) = probe(qw(locked open));
    chmod 0755, "$T/locked";
    is( $rc, 3, 'exit 3: nothing exposed, nothing measured' ) or diag $out;

    like( $out, qr/^  locked: NOT CONFIRMED: the probe folder could not be moved into the private store: cannot create the private store at "[^"]*locked\/public_html-lazysite-private"/m,
        'no store and a locked domain folder: the cause, not "see the warnings"' )
        or diag $out;
    like( $out, qr/^  open: NOT CONFIRMED: the ACL probe got no usable answer/m,
        'a probe that reached the fetch and got nothing: that, in its own words' )
        or diag $out;
    unlike( $out, qr/No reason was given|usually means/, 'and no guess at a cause' )
        or diag( 'SM385: a summary that recommends a repair under a line naming '
            . 'a different cause sends a sysop after the wrong thing.' );
    like( $out, qr/^  - the ACL probe got no usable answer.*\(open\)$/m,
        'the summary lists each reason with its sites' );
};

# --- the rollout: probe_site, extracted and run against a stand-in CLI --------
my $u = slurp($UPD);
my %fn;
for my $n (qw(collect_findings probe_site)) {
    ( $fn{$n} ) = $u =~ /^(\Q$n\E\(\) \{\n.*?^\}\n)/ms;
    ok( $fn{$n}, "the updater defines $n" ) or do { done_testing; exit };
}
my ($noise) = $u =~ /^(NOISE_RE='[^\n]+')$/m;

sub site_probe {
    my ( $rc, $out ) = @_;
    spit( "$T/out.txt", $out );
    spit( "$T/cli.pl", "open my \$f, '<', '$T/out.txt' or die; print <\$f>; exit $rc;\n" );
    spit( "$T/f",      '' );
    spit( "$T/p.sh", "set -u\nVERBOSE=0\nLZS='$T/cli.pl'\nFINDINGS_FILE='$T/f'\n$noise\n"
            . "$fn{collect_findings}$fn{probe_site}PROBE_TOOL_FAILED=''\nprobe_site a.example\n"
            . "echo \"VERDICT=\$PROBE_VERDICT TOOL=\$PROBE_TOOL_FAILED\"\n" );
    my $shown = qx(bash '$T/p.sh' 2>&1);
    return ( $shown, slurp("$T/f") );
}

subtest 'the rollout carries the probe\'s reason as a finding' => sub {
    my ( $shown, $f ) = site_probe( 3,
        "  a.example: NOT CONFIRMED: the probe folder could not be moved into the private store: cannot create it\n"
            . "    [ warn ] ACL PROBE SKIPPED: the engine refused\n\n0 verified, 0 exposed, 1 not confirmed.\n" );
    like( $shown, qr/VERDICT=none TOOL=$/m, 'counted as could not run, not as a tool failure' );
    like( $f, qr/^a\.example\tprobe could not run: the probe folder could not be moved into the private store: cannot create it$/m,
        'the reason is a finding, labelled with the site, grouped like the rest' )
        or diag $f;
    unlike( $shown, qr/full output/, 'and the probe is not dumped whole as a failure' )
        or diag $shown;
};

subtest 'a probe command that did not finish is not an exposure' => sub {
    my ( $shown, $f ) = site_probe( 1, "lazysite: no registered site named 'a.example'. Known: b\n" );
    like( $shown, qr/VERDICT=none TOOL=1$/m, 'could not run - and marked for a human' )
        or diag( 'It was counted as EXPOSED: any status but 0 and 3.' );
    like( $f, qr/probe could not run: the probe command did not finish \(status 1\): lazysite: no registered site named/,
        'with its last line as the reason' )
        or diag $f;
    like( $shown, qr/full output/, 'and its output in full' );

    ( $shown, $f ) = site_probe( 1, "  a.example: SERVED ANONYMOUSLY\n    [ FAIL ] a file the engine refuses is served\n" );
    like( $shown, qr/VERDICT=exposed/, 'an exposure is still an exposure' );
    ( $shown, $f ) = site_probe( 0, "  a.example: front end honours the rule\n" );
    like( $shown, qr/VERDICT=ok/, 'and a pass a pass' );
    is( $f, '', 'with nothing to report' );
};

subtest 'the summary points at the reasons' => sub {
    like( $u, qr/could not run%s\\n' \\\n\s*"\$\{_probe_ok:-0\}"/, 'the probe line has room for a pointer' );
    like( $u, qr/the reason for each is under findings: "probe could not run"/, 'which names the finding' );
};

subtest 'a root --fix creates the store the engine cannot' => sub {
    my $c = slurp("$root/tools/lazysite-check.pl");
    my ($blk) = $c =~ /(unless \( \$gating \|\| -e \$store \) \{.*?\n        return;\n    \})/s;
    ok( $blk, 'the no-protection branch is found' ) or return;
    like( $blk, qr/if \( \$> == 0 \)/, 'as root only' );
    like( $blk, qr/\$store_create_needed = \$store\s+if \@pst && !\( cgi_can\( 2, \@pst \) && cgi_can\( 1, \@pst \) \)/,
        'when the engine cannot create it itself - the shape --fix already creates (SM313)' );

    # And as anybody else, nothing changes: no report, and no nag under --fix.
    plan skip_all => 'running as root' if $> == 0;
    my $doc = a_site('quiet');
    chmod 0551, "$T/quiet";
    my $out = qx($^X \Q$root/tools/lazysite-check.pl\E --docroot \Q$doc\E --fix 2>&1);
    chmod 0755, "$T/quiet";
    unlike( $out, qr/private store/, 'a non-root check says nothing about a store this site does not need' )
        or diag $out;
};

done_testing();
