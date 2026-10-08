#!/usr/bin/perl
# SM971: THE GATE TESTS THE RELEASE MATERIAL; THE BUILD COMMITS IT, ONCE, OR NOT AT ALL.
#
# release.sh gate writes the release material into its stage before the suite
# runs, so it gates what will ship and main can pass at any moment - there is no
# rehearsal any more. release.sh build makes ONE release commit on top of main
# from a passing receipt, checks it touches only release material and that the
# lints reading that material pass, packages it, tags it LOCALLY and moves main
# to it - and on any failure leaves main and the tags as they were.
#
# Driven here end to end: the REAL release.sh, release-material.pl and
# bump-version.pl in a scratch repository, with stand-ins for everything slow
# or host-bound (the suite is a handful of stub tests, the bench, coverage,
# compliance, manifest, SBOM and man pages are one-liners, LAZYSITE_SKIP_DEB=1).
# No real gate, coverage run or push happens.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use File::Temp  qw(tempdir);
use File::Copy  qw(copy);
use Digest::SHA qw(sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd);

my $root = repo_root();
plan skip_all => 'setsid missing' unless grep { -x "$_/setsid" } split /:/, $ENV{PATH};

sub spit {
    my ( $p, $t ) = @_;
    ( my $d = $p ) =~ s{/[^/]+$}{};
    make_path($d);
    open my $f, '>', $p or die "$p: $!";
    print {$f} $t;
    close $f;
}
sub slurp { open my $f, '<', $_[0] or return ''; local $/; my $t = <$f>; close $f; $t }
sub git { my ( $d, @a ) = @_; my $o = run_cmd( 'git', '-C', $d, @a ); die "git @a: $o" if $?; chomp $o; $o }
sub commit { my ( $d, $m ) = @_; git( $d, 'add', '-A' ); git( $d, 'commit', '-q', '-m', $m ); git( $d, 'rev-parse', 'HEAD' ) }

# Gate tools the release refuses to run without - stubs, so the host's own
# copies (or their absence) decide nothing here.
my $BIN = tempdir( CLEANUP => 1 );
for my $t (qw(perlcritic perltidy shellcheck)) { spit( "$BIN/$t", "#!/bin/sh\nexit 0\n" ); chmod 0755, "$BIN/$t" }

my %STANDIN = (
    'tools/import-field-practice.pl' => <<'PL',
use strict; use warnings; use File::Basename qw(dirname); use Cwd qw(abs_path);
my %o = @ARGV; my $root = dirname( dirname( abs_path($0) ) );
open my $f, '>', "$root/starter/docs/ai-briefing-practice.md" or die;
print {$f} "engine-version: $o{'--engine-version'}\n";
PL
    'tools/gen-doc-index.pl' => <<'PL',
use strict; use warnings; use File::Basename qw(dirname); use Cwd qw(abs_path);
my $root = dirname( dirname( abs_path($0) ) );
open my $i, '<', "$root/docs/FEATURES.md" or die; my ($s) = grep { /^subtitle:/ } <$i>;
open my $f, '>', "$root/docs/INDEX.md" or die; print {$f} "index of: $s";
PL
    'tools/lazysite-compliance.pl' => "print qq{compliance: stand-in\\n};\n",
    'tools/build-manifest.pl' => "my %o = \@ARGV; open my \$f, '>', \$o{'--out'} or die; print {\$f} \"{}\\n\";\n",
    'tools/manifest-to-sbom.pl' => "shift; my %o = \@ARGV; open my \$f, '>', \$o{'--out'} or die; print {\$f} \"{}\\n\";\n",
    'tools/gen-manpages.pl' => "use File::Path qw(make_path); make_path(\$ARGV[0]); open my \$f, '>', \"\$ARGV[0]/x.1\" or die; print {\$f} \".TH X 1\\n\";\n",
    'tools/bench.pl'           => "print qq{bench: stand-in\\n};\n",
    'tools/coverage-inputs.pl' => "print qq{" . ( 'c' x 64 ) . " 1\\n};\n",
    'tools/coverage.sh' => "echo 'coverage: all measured production CGIs at or above the floor (stand-in)'\n",
);

my $LINT = "use Test::More; ok( !\$ENV{STUB_LINT_FAIL}, 'a release-material check (stub)' ); done_testing;\n";

sub repo {
    my (%o) = @_;
    my $d = tempdir( CLEANUP => 1 );
    git( $d, 'init',   '-q',         '-b', 'main' );
    git( $d, 'config', 'user.email', 't@example.invalid' );
    git( $d, 'config', 'user.name',  't' );
    make_path("$d/tools");
    copy( "$root/tools/$_", "$d/tools/$_" ) or die "$_: $!" for qw(release.sh release-material.pl bump-version.pl);
    spit( "$d/$_", $STANDIN{$_} ) for keys %STANDIN;
    spit( "$d/$_", $LINT ) for map { "$_-stub.t" } split /\n/, run_cmd( $^X, "$root/tools/release-material.pl", '--lints' ) =~ s/-[^\n]*\.t$/-/mgr;
    # The suite proves it ran on the tree WITH the release material in it.
    spit( "$d/t/unit/00-the-stage-carries-the-material.t", <<'T' );
use Test::More;
open my $v, '<', 'VERSION' or die; chomp( my $ver = <$v> );
open my $c, '<', 'CHANGELOG.md' or die; my $cl = do { local $/; <$c> };
is( $ver, $ENV{STUB_WANT_VERSION} // $ver, 'VERSION is the version being gated' );
like( $cl, qr/^## \Q$ver\E - EDGE: gated before its notes were written/m, 'the section is written' );
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
    spit( "$d/docs/INDEX.md",                        "index\n" );
    spit( "$d/starter/docs/ai-briefing-practice.md", "engine-version: 0.1.0\n" );
    spit( "$d/download/README.md",             "The 0.1.0 set: lazysite-0.1.0.tar.gz\n" );
    spit( "$d/download/lazysite-0.1.0.tar.gz", "old\n" );
    spit( "$d/CHANGELOG.md", "## Unreleased\n\n## 0.1.0 - EDGE: one (2026-01-01)\n\n- SM1 (abcdef12) **one.**\n" );
    commit( $d, 'the first release' );
    git( $d, 'tag', '-a', 'v0.1.0', '-m', 'v0.1.0' );
    spit( "$d/CHANGELOG.md", "## Unreleased\n\n- SM2 (PENDING) **two.**\n\n## 0.1.0 - EDGE: one (2026-01-01)\n\n- SM1 (abcdef12) **one.**\n" );
    commit( $d, 'SM2' );
    return $d;
}

# A receipt as a passing gate leaves it, for main's tip unless told otherwise.
sub receipt {
    my ( $d, %o ) = @_;
    my $tool = sha256_hex( slurp("$d/tools/release-material.pl") );
    my $dir  = "$d/tmp/release-gate/" . ( $o{version} // '0.1.1' );
    make_path($dir);
    spit( "$dir/coverage-last.json", qq({"inputs_digest":"c","result":"pass"}\n) );
    my %f = ( sha => git( $d, 'rev-parse', 'main' ), version => '0.1.1', channel => 'edge', files => 10,
        tests => 20, result => 'pass', coverage => 'reused', coverage_from => 'sha=x', material_tool => $tool,
        finished => 'now', %o );
    delete $f{$_} for grep { !defined $f{$_} } keys %f;
    spit( "$dir/receipt", join '', map { "$_=$f{$_}\n" } sort keys %f );
    return $f{sha};
}

my $NOTES = tempdir( CLEANUP => 1 ) . '/notes.txt';
spit( $NOTES, "Subtitle: the second thing works\nFeatures: Two works (SM2).\nAssisted-by: Claude:test-model\n"
        . "Claude-Session: https://example.invalid/s\n\nlazysite 0.1.1 (edge)\n\nThe annotation.\n" );

sub release {
    my ( $d, @args ) = @_;
    my $stage = tempdir( CLEANUP => 1 );
    local $ENV{PATH}              = "$BIN:$ENV{PATH}";
    local $ENV{LAZYSITE_SKIP_DEB} = 1;
    local $ENV{STUB_WANT_VERSION} = '0.1.1';
    my $out = run_cmd( 'bash', "$d/tools/release.sh", @args, '--stage-dir', $stage );
    return ( $? >> 8, $out );
}
sub tags { git( $_[0], 'tag', '-l', 'v0.1.1' ) }

subtest 'the gate writes the release material into its stage and gates that tree' => sub {
    my $d    = repo();
    my $main = git( $d, 'rev-parse', 'main' );
    my ( $rc, $out ) = release( $d, 'gate', '0.1.1', '--commit', $main );
    is( $rc, 0, 'the gate passes' ) or diag($out);
    my $r = slurp("$d/tmp/release-gate/0.1.1/receipt");
    like( $r, qr/^sha=$main$/m,   'a receipt for the commit' );
    like( $r, qr/^result=pass$/m, 'that passed' );
    my $tool = sha256_hex( slurp("$d/tools/release-material.pl") );
    like( $r, qr/^material_tool=$tool$/m,          'naming the generator it ran' );
    like( $r, qr/^material_commit=[0-9a-f]{40}$/m, 'and the stage commit holding its output' );
    like( slurp("$d/tmp/release-gate/0.1.1/suite.txt"), qr/00-the-stage-carries-the-material\.t \.+ ok/,
        'the suite ran on the tree with VERSION 0.1.1 and the section written' );
    like( slurp("$d/tmp/release-gate/0.1.1/material.txt"), qr/CHANGELOG\.md/, 'the material is beside the receipt' );
    is( git( $d, 'rev-parse', 'main' ),        $main, 'main is untouched' );
    is( git( $d, 'status',    '--porcelain' ), '',    'and so is the checkout' );
    is( tags($d), '', 'and nothing is tagged' );
    ( $rc, $out ) = release( $d, 'gate', '0.1.1', '--rehearse' );
    is( $rc, 2, 'there is no rehearsal: --rehearse is an unknown flag' );
};

subtest 'build: one release commit on main, tagged, from the receipt' => sub {
    my $d     = repo();
    my $gated = receipt($d);
    my ( $rc, $out ) = release( $d, 'build', '0.1.1', '--notes', $NOTES );
    is( $rc, 0, 'the build passes' ) or return diag($out);
    my $rel = git( $d, 'rev-parse', 'v0.1.1^{commit}' );
    is( git( $d, 'rev-parse', 'main' ),  $rel,   'main IS the release commit' );
    is( git( $d, 'rev-parse', "$rel^" ), $gated, 'on top of the gated main' );
    my %allowed = map { $_ => 1 } split /\n/, run_cmd( $^X, "$d/tools/release-material.pl", '--paths' );
    my @paths = split /\n/, git( $d, 'diff', '--name-only', $gated, $rel );
    is_deeply( [ grep { !$allowed{$_} } @paths ], [], 'touching release material only' );
    ok( ( grep { $_ eq 'docs/releases/GATE-LOG.md' } @paths ), 'the GATE-LOG row is IN the release commit' );
    ok( ( grep { $_ eq 'dist/config/coverage-last.json' } @paths ), 'and so is the coverage record' );
    like( slurp("$d/docs/releases/GATE-LOG.md"), qr/^\| 0\.1\.1 \| edge \| `$gated` \| 10 \| 20 \|/m,
        'the row names the gated commit and its counts' );
    like( slurp("$d/CHANGELOG.md"), qr/^## 0\.1\.1 - EDGE: the second thing works \(\d{4}-\d\d-\d\d\)$/m,
        'the section has the notes\' subtitle' );
    is( slurp("$d/VERSION"), "0.1.1\n", 'the checkout on main moved with it' );
    my $msg = git( $d, 'log', '-1', '--format=%B', $rel );
    like( $msg, qr/^lazysite 0\.1\.1 \(edge\): the second thing works$/m, 'the commit is named' );
    like( $msg, qr/\n\nAssisted-by: Claude:test-model\nClaude-Session: https:\/\/example\.invalid\/s\n*\z/,
        'and ends with the trailers from the notes' );
    like( git( $d, 'tag', '-l', '--format=%(contents)', 'v0.1.1' ), qr/\Alazysite 0\.1\.1 \(edge\)\n\nThe annotation\.\n*\z/,
        'the tag is annotated with the notes\' body' );
    ok( -f "$d/dist/lazysite-0.1.1.tar.gz", 'the tarball is in dist/' );
    is( git( $d, 'worktree', 'list', '--porcelain' ) =~ tr/\n// > 4 ? 'stale' : 'clean', 'clean',
        'the build worktree is gone' );
    like( $out, qr/tools\/release\.sh publish 0\.1\.1/, 'and it names the release manager\'s step' );
};

subtest 'build moves the main ref when main is checked out nowhere' => sub {
    my $d = repo();
    receipt($d);
    git( $d, 'checkout', '-q', '-b', 'elsewhere' );
    my ( $rc, $out ) = release( $d, 'build', '0.1.1', '--notes', $NOTES );
    is( $rc, 0, 'the build passes' ) or return diag($out);
    is( git( $d, 'rev-parse', 'main' ), git( $d, 'rev-parse', 'v0.1.1^{commit}' ), 'main is the release commit' );
    is( git( $d, 'branch', '--show-current' ), 'elsewhere', 'and the checkout was left where it was' );
};

# Each refusal: exit non-zero, a reason, main where it was and no tag.
sub refused {
    my ( $name, $d, $want, @env ) = @_;
    my $main = git( $d, 'rev-parse', 'main' );
    local %ENV = ( %ENV, @env );
    my ( $rc, $out ) = release( $d, 'build', '0.1.1', '--notes', $NOTES );
    isnt( $rc, 0, "$name: refused" );
    like( $out, $want, "$name: saying why" ) or diag($out);
    is( git( $d, 'rev-parse', 'main' ), $main, "$name: main is unchanged" );
    is( tags($d),                       '',    "$name: nothing is tagged" );
}

subtest 'build refuses a main that moved past its gate, unless only release material moved' => sub {
    my $d = repo();
    receipt($d);
    spit( "$d/tools/new-tool.pl", "1;\n" );
    commit( $d, 'a landing after the gate' );
    refused( 'moved', $d, qr/changed\s+.*more than release material.*\n.*tools\/new-tool\.pl/s );

    my $e     = repo();
    my $gated = receipt($e);
    spit( "$e/docs/FEATURES.md", slurp("$e/docs/FEATURES.md") . "\n" );
    commit( $e, 'a FEATURES fix after the gate' );
    my ( $rc, $out ) = release( $e, 'build', '0.1.1', '--notes', $NOTES );
    is( $rc, 0, 'a main moved only in release material is built' ) or diag($out);
    like( $out, qr/moved past the gated commit .* only in release material/, 'saying so' );
    is( git( $e, 'rev-parse', 'v0.1.1^{commit}^' ), git( $e, 'rev-parse', 'main^' ), 'on top of main as it is' );
    like( slurp("$e/docs/releases/GATE-LOG.md"), qr/`$gated`/, 'and the row still names the gated commit' );
};

subtest 'build refuses a release commit that touches anything else' => sub {
    my $d = repo();
    # A generator that also writes outside the allowlist, AFTER its own check
    # has passed - so it is the build's check that must catch it.
    my $gen = slurp("$d/tools/release-material.pl");
    $gen =~ s/^(print "release-material: \$_\\n" for \@said;)$/$1\nopen my \$x, '>', "\$DIR\/extra.txt" or die;\nclose \$x;/m
        or die 'the generator\'s last line moved';
    spit( "$d/tools/release-material.pl", $gen );
    commit( $d, 'a generator that strays' );
    receipt($d);
    refused( 'outside', $d, qr/outside the release-material allowlist:\s*\nrelease\.sh: extra\.txt/ );
};

subtest 'build refuses when a check on the release material fails' => sub {
    my $d = repo();
    receipt($d);
    refused( 'lint', $d, qr/a check on the release material failed/, STUB_LINT_FAIL => 1 );
};

subtest 'build refuses a receipt that does not cover this build' => sub {
    my $d = repo();
    refused( 'no receipt', $d, qr/no gate receipt for 0\.1\.1/ );
    receipt( $d, material_tool => undef );
    refused( 'pre-SM971 receipt', $d, qr/does not match this build/ );
    receipt( $d, channel => 'beta' );
    refused( 'other channel', $d, qr/does not match this build/ );
    receipt($d);
    spit( "$d/../no-attribution-$$.txt", "Subtitle: s\nFeatures: f\n\nbody\n" );
    my ( $rc, $out ) = release( $d, 'build', '0.1.1', '--notes', "$d/../no-attribution-$$.txt" );
    is( $rc, 2, 'notes with no Assisted-by are refused' );
    like( $out, qr/no 'Assisted-by:' header/, 'naming the header' );
    unlink "$d/../no-attribution-$$.txt";
    spit( "$d/VERSION", "dirty\n" );
    refused( 'dirty main', $d, qr/main is checked out at .* with uncommitted changes/ );
};

subtest 'a stable cut adds the download set as a second commit; the tag stays on the release' => sub {
    my $d = repo();
    receipt( $d, channel => 'stable' );
    my ( $rc, $out ) = release( $d, 'build', '0.1.1', '--notes', $NOTES, '--final' );
    is( $rc, 0, 'the build passes' ) or return diag($out);
    my $rel  = git( $d, 'rev-parse', 'v0.1.1^{commit}' );
    my $main = git( $d, 'rev-parse', 'main' );
    is( git( $d, 'rev-parse', 'main^' ), $rel, 'main is one commit past the tagged release commit' );
    is( git( $d, 'diff', '--name-only', $rel, $main ) =~ s{download/[^\n]*\n?}{}gr, '', 'touching download/ only' );
    ok( -f "$d/download/lazysite-0.1.1.tar.gz",  'the new tarball is there' );
    ok( !-e "$d/download/lazysite-0.1.0.tar.gz", 'the old one is gone' );
    like( slurp("$d/download/README.md"), qr/The 0\.1\.1 set: lazysite-0\.1\.1\.tar\.gz/, 'and the README names it' );
};

done_testing();
