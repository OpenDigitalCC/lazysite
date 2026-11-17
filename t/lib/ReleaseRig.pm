package ReleaseRig;
# SM1454: a scratch repository the REAL tools/release.sh gates and builds in.
#
# The same rig t/tools/104 drives (its stand-ins are copied there, and left there),
# for the tests of the gate's suite stage: the suite record, --patch, the receipt.
# The real release.sh, release-material.pl and bump-version.pl run in a scratch
# repository; everything slow or host-bound (the bench, coverage, compliance, the
# manifest, SBOM and man pages) is a one-line stand-in, and the "suite" is a few
# stub tests that log each time they run (STUB_RUN_LOG), so a test can say what ran.
# No real gate, coverage run or push happens.
use strict;
use warnings;
use Exporter 'import';
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use File::Temp  qw(tempdir);
use Digest::SHA qw(sha256_hex);
use TestHelper  qw(repo_root run_cmd);

our @EXPORT_OK = qw(spit slurp git commit logger rig_repo rig_release rig_receipt rig_base_receipt rig_notes rig_tags rig_runs rig_patch_branch);

my $root = repo_root();

sub spit {
    my ( $p, $t ) = @_;
    ( my $d = $p ) =~ s{/[^/]+$}{};
    make_path($d);
    open my $f, '>', $p or die "$p: $!";
    print {$f} $t;
    close $f;
}
sub slurp { open my $f, '<', $_[0] or return ''; local $/; my $t = <$f>; close $f; $t }

# Devel::Cover (PERL5OPT) prints to stderr, which run_cmd folds in; not our business.
sub git { my ( $d, @a ) = @_; my $o = run_cmd( 'git', '-C', $d, @a ); die "git @a: $o" if $?; $o =~ s/^Devel::Cover:[^\n]*\n?//mg; chomp $o; $o }
sub commit { my ( $d, $m ) = @_; git( $d, 'add', '-A' ); git( $d, 'commit', '-q', '-m', $m ); git( $d, 'rev-parse', 'HEAD' ) }

# A test that appends its label to $STUB_RUN_LOG when it runs, and passes.
sub logger {
    my ($label) = @_;
    return "use Test::More;\nif ( \$ENV{STUB_RUN_LOG} ) { open my \$f, '>>', \$ENV{STUB_RUN_LOG} or die; print {\$f} \"$label\\n\"; close \$f }\n"
        . "ok( 1, '$label' );\ndone_testing;\n";
}

# The nested builds' stage is on DISK when /tmp is a RAM-backed tmpfs (t/tools/104).
my $STAGE_DIR = ( run_cmd( 'stat', '-f', '-c', '%T', File::Spec->tmpdir ) =~ /tmpfs|ramfs/ && -d '/var/tmp' && -w '/var/tmp' ) ? '/var/tmp' : undef;

# Gate tools the release refuses to run without - stubs, so the host's own decide nothing.
my $BIN = tempdir( CLEANUP => 1 );
for my $t (qw(perlcritic perltidy shellcheck)) { spit( "$BIN/$t", "#!/bin/sh\nexit 0\n" ); chmod 0755, "$BIN/$t" }

my %STANDIN = (
    'tools/import-field-practice.pl' => <<'PL',
use strict; use warnings; use File::Basename qw(dirname); use Cwd qw(abs_path);
my %o = @ARGV; my $root = dirname( dirname( abs_path($0) ) );
open my $f, '>', "$root/starter/lazysite/templates/docs/ai-briefing-practice.md" or die;
print {$f} "engine-version: $o{'--engine-version'}\n";
PL
    'tools/gen-doc-index.pl' => <<'PL',
use strict; use warnings; use File::Basename qw(dirname); use Cwd qw(abs_path);
my $root = dirname( dirname( abs_path($0) ) );
open my $i, '<', "$root/docs/FEATURES.md" or die; my ($s) = grep { /^subtitle:/ } <$i>;
open my $f, '>', "$root/docs/INDEX.md" or die; print {$f} "index of: $s";
PL
    'tools/lazysite-compliance.pl' => "print qq{compliance: stand-in\\n};\n",
    'tools/build-manifest.pl' => "my \$sc = grep { \$_ eq '--security-critical' } \@ARGV;\n"
        . "my %o = grep { \$_ ne '--security-critical' } \@ARGV; open my \$f, '>', \$o{'--out'} or die;\n"
        . "print {\$f} \$sc ? qq({\"security_critical\":true}\\n) : \"{}\\n\";\n",
    'tools/manifest-to-sbom.pl' => "shift; my %o = \@ARGV; open my \$f, '>', \$o{'--out'} or die; print {\$f} \"{}\\n\";\n",
    'tools/gen-manpages.pl' => "use File::Path qw(make_path); make_path(\$ARGV[0]); open my \$f, '>', \"\$ARGV[0]/x.1\" or die; print {\$f} \".TH X 1\\n\";\n",
    'tools/bench.pl'           => "print qq{bench: stand-in\\n};\n",
    'tools/coverage-inputs.pl' => "print qq{" . ( 'c' x 64 ) . " 1\\n};\n",
    'tools/coverage.sh' => "echo 'coverage: all measured production CGIs at or above the floor (stand-in)'\n",
);

my $LINT = "use Test::More; ok( !\$ENV{STUB_LINT_FAIL}, 'a release-material check (stub)' ); done_testing;\n";

# repo( tools => [real tools to carry], base => { path => text } in the tagged first
# commit, change => { path => text } in the commit after it ). Tag v0.1.0 is the
# first commit; main is the second, which stamps CHANGELOG's SM2 entry PENDING.
sub rig_repo {
    my (%o) = @_;
    my $d = tempdir( CLEANUP => 1 );
    git( $d, 'init',   '-q',         '-b', 'main' );
    git( $d, 'config', 'user.email', 't@example.invalid' );
    git( $d, 'config', 'user.name',  't' );
    make_path("$d/tools");
    copy( "$root/tools/$_", "$d/tools/$_" ) or die "$_: $!" for qw(release.sh release-material.pl bump-version.pl), @{ $o{tools} // [] };
    spit( "$d/$_", $STANDIN{$_} ) for keys %STANDIN;
    spit( "$d/$_", $LINT ) for map { "$_-stub.t" } split /\n/, run_cmd( $^X, "$root/tools/release-material.pl", '--lints' ) =~ s/-[^\n]*\.t$/-/mgr;
# The suite proves it ran on the tree WITH the release material in it, and logs, and can fail.
    spit( "$d/t/unit/00-the-stage-carries-the-material.t", <<'T' );
use Test::More;
open my $v, '<', 'VERSION' or die; chomp( my $ver = <$v> );
open my $c, '<', 'CHANGELOG.md' or die; my $cl = do { local $/; <$c> };
if ( $ENV{STUB_RUN_LOG} ) { open my $f, '>>', $ENV{STUB_RUN_LOG} or die; print {$f} "suite\n"; close $f }
is( $ver, $ENV{STUB_WANT_VERSION} // $ver, 'VERSION is the version being gated' );
like( $cl, qr/^## \Q$ver\E - [A-Z]+: gated before its notes were written/m, 'the section is written' );
ok( !$ENV{STUB_SUITE_FAIL}, 'the suite stub is told to pass' );
done_testing;
T
    spit( "$d/dist/config/sbom-deps.json", "{}\n" );
    spit( "$d/.gitignore",                 "tmp/\ndist/*.tar.gz\ndist/*.sha256\n" );
    spit( "$d/VERSION",                    "0.1.0\n" );
    spit( "$d/NEXT_VERSION",               "0.1.1\n" );
    spit( "$d/docs/FEATURES.md",
        "---\nsubtitle: \"Everything - as of v0.1.0\"\n---\n\nNewest first; releases are git tags.\n\n- **0.1.0** (2026-01-01, edge) - **One.**\n" );
    spit( "$d/docs/releases/CHANGELOG-archive.md", "---\ntitle: \"Archive\"\n---\n\n## 0.0.1 - EDGE: old (2025-01-01)\n" );
    spit( "$d/docs/releases/GATE-LOG.md", "| Version | Channel | Commit | Files | Tests | Gated (UTC) |\n|---|---|---|---|---|---|\n" );
    spit( "$d/docs/INDEX.md",                                           "index\n" );
    spit( "$d/starter/lazysite/templates/docs/ai-briefing-practice.md", "engine-version: 0.1.0\n" );
    spit( "$d/download/README.md",             "The 0.1.0 set: lazysite-0.1.0.tar.gz\n" );
    spit( "$d/download/lazysite-0.1.0.tar.gz", "old\n" );
    spit( "$d/CHANGELOG.md", "## Unreleased\n\n## 0.1.0 - EDGE: one (2026-01-01)\n\n- SM1 (abcdef12) **one.**\n" );
    spit( "$d/$_", $o{base}{$_} ) for keys %{ $o{base} // {} };
    commit( $d, 'the first release' );
    git( $d, 'tag', '-a', 'v0.1.0', '-m', 'v0.1.0' );
    spit( "$d/CHANGELOG.md", "## Unreleased\n\n- SM2 (PENDING) **two.**\n\n## 0.1.0 - EDGE: one (2026-01-01)\n\n- SM1 (abcdef12) **one.**\n" );
    spit( "$d/$_", $o{change}{$_} ) for keys %{ $o{change} // {} };
    commit( $d, 'SM2' );
    return $d;
}

# A receipt as a passing gate leaves it, for main's tip unless told otherwise.
sub rig_receipt {
    my ( $d, %o ) = @_;
    my $tool = sha256_hex( slurp("$d/tools/release-material.pl") );
    my $dir  = "$d/tmp/release-gate/" . ( delete $o{dir} // $o{version} // '0.1.1' );
    make_path($dir);
    spit( "$dir/coverage-last.json", qq({"inputs_digest":"c","result":"pass"}\n) );
    my %f = ( sha => git( $d, 'rev-parse', 'main' ), version => '0.1.1', channel => 'edge', files => 10,
        tests => 20, result => 'pass', coverage => 'reused', coverage_from => 'sha=x', material_tool => $tool,
        finished => 'now', %o );
    delete $f{$_} for grep { !defined $f{$_} } keys %f;
    spit( "$dir/receipt", join '', map { "$_=$f{$_}\n" } sort keys %f );
    return $f{sha};
}

# A passing receipt for the base release, as its own gate left it.
sub rig_base_receipt { my ( $d, %o ) = @_; return rig_receipt( $d, dir => '0.1.0', version => '0.1.0', channel => 'stable', %o ) }

sub rig_notes {
    my $n = tempdir( CLEANUP => 1 ) . '/notes.txt';
    spit( $n, "Subtitle: the second thing works\nFeatures: Two works (SM2).\nAssisted-by: Claude:test-model\n"
            . "Claude-Session: https://example.invalid/s\n\nlazysite 0.1.1 (edge)\n\nThe annotation.\n" );
    return $n;
}

# Run release.sh in $d. %$env is added to the environment for the run.
sub rig_release {
    my ( $d, $env, @args ) = @_;
    my $stage = tempdir( CLEANUP => 1, ( $STAGE_DIR ? ( DIR => $STAGE_DIR ) : () ) );
    local $ENV{PATH}                   = "$BIN:$ENV{PATH}";
    local $ENV{LAZYSITE_SKIP_DEB}      = 1;
    local $ENV{STUB_WANT_VERSION}      = '0.1.1';
    local @ENV{ keys %{ $env // {} } } = values %{ $env // {} };
    my $out = run_cmd( 'bash', "$d/tools/release.sh", @args, '--stage-dir', $stage );
    return ( $? >> 8, $out );
}

sub rig_tags { git( $_[0], 'tag', '-l', 'v0.1.1' ) }

# The labels a run logged, in order of arrival, as a sorted list.
sub rig_runs { my ($log) = @_; return [ sort grep { length } split /\n/, slurp($log) ] }

# SM1475: a stable patch branch NAME in $d, from $o{from} (the base tag by default), with one
# commit - a fix and its PENDING changelog bullet, plus %{$o{files}} (path => text, undef
# removes it). The commit is made in a throwaway worktree, so nothing is checked out in $d.
# Returns the branch's tip.
sub rig_patch_branch {
    my ( $d, $name, %o ) = @_;
    my $wt = tempdir( CLEANUP => 1 ) . '/wt';
    git( $d, 'worktree', 'add', '-q', '-b', $name, $wt, $o{from} // 'v0.1.0' );
    spit( "$wt/docs/fix.md", "the fix\n" );
    my $cl = slurp("$wt/CHANGELOG.md");
    $cl =~ s{^## Unreleased\n\n}{## Unreleased\n\n- SM3 (PENDING) **three.**\n\n}m or die 'no Unreleased section';
    spit( "$wt/CHANGELOG.md", $cl );
    for my $p ( keys %{ $o{files} // {} } ) {
        defined $o{files}{$p} ? spit( "$wt/$p", $o{files}{$p} ) : unlink "$wt/$p";
    }
    my $tip = commit( $wt, 'SM3: the fix' );
    git( $d, 'worktree', 'remove', '--force', $wt );
    return $tip;
}

1;
