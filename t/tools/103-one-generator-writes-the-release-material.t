#!/usr/bin/perl
# SM971: ONE GENERATOR WRITES A RELEASE'S MECHANICAL MATERIAL, AND NEVER GUESSES.
#
# A cut needed a pre-cut landing (the section retitled, the FEATURES entry, the
# briefing re-imported, the index regenerated) before main could pass a gate,
# and a post-release landing (PENDING refs, VERSION/NEXT_VERSION, the archive at
# a new minor) after it. tools/release-material.pl writes all of it into a
# checkout; the gate runs it in its stage and the build in the release commit.
# Asserted here on scratch repositories, with stand-ins for the importer and
# the index generator (the real tools are reused by the generator, not copied
# into it) and the real bump-version.pl:
#
#   - the heading in the house format, under a fresh Unreleased, with a
#     placeholder subtitle without notes and the notes' subtitle with them;
#   - every PENDING ref replaced by the landed SHA of the commit that added that
#     exact line, and a refusal - nothing written - when there is no such commit
#     since the last tag, more than one, or the line twice;
#   - VERSION X.Y.Z and NEXT_VERSION X.Y.(Z+1);
#   - the FEATURES entry and subtitle; the briefing and index rewritten;
#   - at X.Y.0 the earlier minors moved, unchanged, to the archive;
#   - its output stays inside the allowlist it publishes.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd);

my $root = repo_root();
my $GEN  = 'tools/release-material.pl';

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

my $IMPORT = <<'PL';
#!/usr/bin/perl
use strict; use warnings;
my %o = @ARGV;
use File::Basename qw(dirname); use Cwd qw(abs_path);
my $root = dirname( dirname( abs_path($0) ) );
open my $f, '>', "$root/starter/docs/ai-briefing-practice.md" or die;
print {$f} "engine-version: $o{'--engine-version'}\nimported: $o{'--date'}\n";
PL
my $INDEX = <<'PL';
#!/usr/bin/perl
use strict; use warnings;
use File::Basename qw(dirname); use Cwd qw(abs_path);
my $root = dirname( dirname( abs_path($0) ) );
open my $i, '<', "$root/docs/FEATURES.md" or die; my ($sub) = grep { /^subtitle:/ } <$i>;
open my $f, '>', "$root/docs/INDEX.md" or die; print {$f} "index of: $sub";
PL

my $ABOUT = "---\ntitle: \"Changelog\"\n---\n\n## About this changelog\n\nWrite `(PENDING)` until it lands.\n\n";
my $OLD = "## 0.1.0 - EDGE: the first (2026-01-01)\n\n- SM1 (abcdef12) **the first thing.**\n";

# A repository with one release (v0.1.0) and two entries landed after it, each
# in its own commit. Returns the directory and the two landing SHAs.
sub repo {
    my $d = tempdir( CLEANUP => 1 );
    git( $d, 'init',   '-q',         '-b', 'main' );
    git( $d, 'config', 'user.email', 't@example.invalid' );
    git( $d, 'config', 'user.name',  't' );
    make_path("$d/tools");
    copy( "$root/$GEN",                  "$d/$GEN" )                  or die $!;
    copy( "$root/tools/bump-version.pl", "$d/tools/bump-version.pl" ) or die $!;
    spit( "$d/tools/import-field-practice.pl", $IMPORT );
    spit( "$d/tools/gen-doc-index.pl",         $INDEX );
    spit( "$d/VERSION",                        "0.1.0\n" );
    spit( "$d/NEXT_VERSION",                   "0.1.1\n" );
    spit( "$d/docs/FEATURES.md",
        "---\nsubtitle: \"Everything - as of v0.1.0\"\n---\n\n# Timeline\n\nNewest first; releases are git tags.\n\n"
            . "- **0.1.0** (2026-01-01, edge) - **The first.** It began.\n" );
    spit( "$d/docs/releases/CHANGELOG-archive.md", "---\ntitle: \"Archive\"\n---\n\n## 0.0.9 - EDGE: older (2025-12-01)\n\n- old\n" );
    spit( "$d/docs/INDEX.md",                        "index\n" );
    spit( "$d/starter/docs/ai-briefing-practice.md", "engine-version: 0.1.0\n" );
    spit( "$d/CHANGELOG.md",                         "$ABOUT## Unreleased\n\n$OLD" );
    commit( $d, 'the first release' );
    git( $d, 'tag', '-a', 'v0.1.0', '-m', 'v0.1.0' );
    spit( "$d/CHANGELOG.md", "$ABOUT## Unreleased\n\n- SM2 (PENDING) **the second thing.**\n  More about it.\n\n$OLD" );
    my $s2 = commit( $d, 'SM2' );
    spit( "$d/CHANGELOG.md",
        "$ABOUT## Unreleased\n\n- SM3 stage 1 (PENDING) **the third thing.**\n\n- SM2 (PENDING) **the second thing.**\n  More about it.\n\n$OLD" );
    my $s3 = commit( $d, 'SM3' );
    return ( $d, $s2, $s3 );
}

sub gen {
    my ( $d, @args ) = @_;
    my $out = run_cmd( $^X, "$d/$GEN", @args );
    return ( $? >> 8, $out );
}

subtest 'the gate form: house heading, every PENDING stamped, the pair rolled' => sub {
    my ( $d, $s2, $s3 ) = repo();
    my ( $rc, $out ) = gen( $d, '0.1.1', '--dir', $d, '--date', '2026-10-08' );
    is( $rc, 0, 'exit 0' ) or diag($out);
    my $c = slurp("$d/CHANGELOG.md");
    like( $c, qr/^## Unreleased\n\n## 0\.1\.1 - EDGE: gated before its notes were written \(2026-10-08\)\n\n- SM3/m,
        'Unreleased becomes the version heading, a fresh Unreleased above it' );
    my ( $a2, $a3 ) = map { substr $_, 0, 8 } $s2, $s3;
    like( $c, qr/^- SM2 \($a2\) \*\*the second thing/m, 'SM2 names the commit that added its line' );
    like( $c, qr/^- SM3 stage 1 \($a3\) \*\*the third/m, 'SM3 names its own, not the newest commit' );
    unlike( $c, qr/^- \S.*\(PENDING\)/m, 'no entry line is PENDING' );
    like( $c, qr/Write `\(PENDING\)` until it lands/, 'prose naming PENDING outside an entry is left alone' );
    is( slurp("$d/VERSION"),      "0.1.1\n", 'VERSION is the release' );
    is( slurp("$d/NEXT_VERSION"), "0.1.2\n", 'NEXT_VERSION the patch after it' );
    my $f = slurp("$d/docs/FEATURES.md");
    like( $f, qr/as of v0\.1\.1"/, 'the FEATURES subtitle names the release' );
    like( $f, qr/git tags\.\n\n- \*\*0\.1\.1\*\* \(2026-10-08, edge\) - \*\*Gated before its notes were written\.\*\*/,
        'and the timeline entry is the newest' );
    like( slurp("$d/starter/docs/ai-briefing-practice.md"), qr/engine-version: 0\.1\.1/, 'the briefing is re-imported for it' );
    like( slurp("$d/docs/INDEX.md"), qr/as of v0\.1\.1/, 'the index is regenerated after FEATURES' );
    my %allowed = map { $_ => 1 } split /\n/, ( gen( $d, '--paths' ) )[1];
    my @changed = map { substr $_, 3 } split /\n/, git( $d, 'status', '--porcelain' );
    ok( scalar @changed, 'it changed files' );
    is_deeply( [ grep { !$allowed{$_} } @changed ], [], 'every one of them on the allowlist' );
    is( slurp("$d/docs/releases/CHANGELOG-archive.md") =~ tr/#//, 2, 'a patch release moves nothing to the archive' );
};

subtest 'the build form: the notes give the subtitle and the FEATURES text' => sub {
    my ($d) = repo();
    spit( "$d/../notes-$$.txt",
        "Subtitle: a thing that works\nFeatures: It works now (SM2), and the third thing is"
            . " here too (SM3) - a sentence long enough to be wrapped onto a second line.\n"
            . "Assisted-by: Claude:test\n\nlazysite 0.1.1 (beta)\n\nThe annotation.\n" );
    my ( $rc, $out ) = gen( $d, '0.1.1', '--dir', $d, '--channel', 'beta', '--notes', "$d/../notes-$$.txt",
        '--date', '2026-10-09' );
    is( $rc, 0, 'exit 0' ) or diag($out);
    like( slurp("$d/CHANGELOG.md"), qr/^## 0\.1\.1 - BETA: a thing that works \(2026-10-09\)$/m, 'the heading' );
    my $f = slurp("$d/docs/FEATURES.md");
    like( $f, qr/^- \*\*0\.1\.1\*\* \(2026-10-09, beta\) - \*\*A thing that works\.\*\* It works now/m, 'the entry' );
    my ($entry) = $f =~ /^(- \*\*0\.1\.1\*\*.*?)\n- \*\*0\.1\.0/ms;
    ok( $entry && $entry =~ /\n  \S/, 'wrapped, continuation lines indented two' );
    is( scalar( grep { length > 79 } split /\n/, $entry // '' ), 0, 'no line over 79 characters' );
    ( $rc, $out ) = gen( $d, '--notes', "$d/../notes-$$.txt", '--print', 'trailers' );
    is( $out, "Assisted-by: Claude:test\n", 'the trailers are the notes\' attribution headers' );
    ( $rc, $out ) = gen( $d, '--notes', "$d/../notes-$$.txt", '--print', 'annotation' );
    is( $out, "lazysite 0.1.1 (beta)\n\nThe annotation.\n", 'the annotation is everything after the header' );
    unlink "$d/../notes-$$.txt";
};

subtest 'a PENDING ref it cannot resolve unambiguously is refused, and nothing is written' => sub {
    my %case = (
        'no commit since the last tag added it' => sub {
            my ($d) = @_;    # entries still PENDING when a later release was tagged
            git( $d, 'tag', '-a', 'v0.1.5', '-m', 'v0.1.5' );
            return qr/- SM2 \(PENDING\).*\n\s+no commit in v0\.1\.5\.\.HEAD added this line/;
        },
        'the same line twice' => sub {
            my ($d) = @_;
            spit( "$d/CHANGELOG.md", slurp("$d/CHANGELOG.md") =~ s/(## 0\.1\.0)/- SM2 (PENDING) **the second thing.**\n\n$1/r );
            commit( $d, 'a duplicate' );
            return qr/appears 2 times/;
        },
        'two commits added that exact line' => sub {
            my ($d) = @_;
            my $c = slurp("$d/CHANGELOG.md");
            spit( "$d/CHANGELOG.md", $c =~ s/^- SM3 stage 1 \(PENDING\) \*\*the third thing\.\*\*\n\n//mr );
            commit( $d, 'drop SM3' );
            spit( "$d/CHANGELOG.md", $c );
            commit( $d, 'restore SM3' );
            return qr/2 commits added this exact line/;
        },
    );
    for my $name ( sort keys %case ) {
        my ($d) = repo();
        my $want = $case{$name}->($d);
        my ( $rc, $out ) = gen( $d, '0.1.1', '--dir', $d );
        is( $rc, 1, "$name: refused" ) or diag($out);
        like( $out, $want, "$name: naming the entry and why" );
        is( git( $d, 'status', '--porcelain' ), '', "$name: the checkout is untouched" );
    }
};

subtest 'a new minor moves the earlier minors to the archive, unchanged' => sub {
    my ($d) = repo();
    my ( $rc, $out ) = gen( $d, '0.2.0', '--dir', $d );
    is( $rc, 0, 'exit 0' ) or diag($out);
    my $c = slurp("$d/CHANGELOG.md");
    unlike( $c, qr/^## 0\.1\./m, 'no 0.1.x section is left in CHANGELOG.md' );
    like( $c, qr/^## 0\.2\.0 - EDGE: /m,     'the new one is there' );
    like( $c, qr/^## About this changelog/m, 'and so is the About section' );
    is( slurp("$d/docs/releases/CHANGELOG-archive.md"),
        "---\ntitle: \"Archive\"\n---\n\n$OLD\n## 0.0.9 - EDGE: older (2025-12-01)\n\n- old\n",
        'the 0.1.0 section heads the archive, byte for byte, above the older ones' );
    is( slurp("$d/NEXT_VERSION"), "0.2.1\n", 'NEXT_VERSION 0.2.1' );
};

subtest 'it refuses what it cannot do cleanly' => sub {
    my ($d) = repo();
    spit( "$d/stray", "x\n" );
    my ( $rc, $out ) = gen( $d, '0.1.1', '--dir', $d );
    is( $rc, 1, 'a dirty checkout is refused' );
    like( $out, qr/uncommitted changes/, 'saying so' );
    unlink "$d/stray";
    spit( "$d/../bad-$$.txt", "Subtitle: only a subtitle\n\nbody\n" );
    ( $rc, $out ) = gen( $d, '0.1.1', '--dir', $d, '--notes', "$d/../bad-$$.txt" );
    is( $rc, 1, 'notes with no Features header are refused' );
    like( $out, qr/no 'Features:' header/, 'naming it' );
    unlink "$d/../bad-$$.txt";
    ( $rc, $out ) = gen( $d, '0.1', '--dir', $d );
    is( $rc, 2, 'a version that is not X.Y.Z is a usage error' );
    is( git( $d, 'status', '--porcelain' ), '', 'and nothing was written' );
};

subtest 'the allowlist and the checks it publishes' => sub {
    my ( $rc, $out ) = gen( $root, '--paths' );
    is( $out, join( '', map { "$_\n" } qw(CHANGELOG.md docs/releases/CHANGELOG-archive.md docs/FEATURES.md
                docs/INDEX.md starter/docs/ai-briefing-practice.md VERSION NEXT_VERSION docs/releases/GATE-LOG.md
                dist/config/coverage-last.json) ), 'the release-material allowlist, exactly' );
    ( $rc, $out ) = gen( $root, '--lints', '--dir', $root );
    is( $rc, 0, '--lints resolves every listed check in this tree' ) or diag($out);
    ok( ( grep { -f "$root/$_" } split /\n/, $out ) == ( () = $out =~ /\n/g ), 'to files that exist' );
    my $d = tempdir( CLEANUP => 1 );
    ( $rc, $out ) = gen( $root, '--lints', '--dir', $d );
    is( $rc, 1, 'and refuses a tree that lacks one' );
};

done_testing();
