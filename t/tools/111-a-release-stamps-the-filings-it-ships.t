#!/usr/bin/perl
# P22 (WORK-PLAN-0154, ruled 2026-10-12): the release step stamps "SHIPPED
# (PENDING)" status-notes with the released version.
#
# A filing is written on its branch, before anyone knows which release will
# carry it, so it says SHIPPED (PENDING) - and nothing ever replaced that, so 31
# filings said PENDING after their release shipped. tools/release-material.pl,
# which the gate and the build both run, now stamps every filing whose id has an
# entry in the section being released. Asserted on a scratch repository, as
# t/tools/103 asserts the rest of the generator.
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
    return;
}
sub slurp { open my $f, '<', $_[0] or return ''; local $/; my $t = <$f>; close $f; return $t }
sub git { my ( $d, @a ) = @_; my $o = run_cmd( 'git', '-C', $d, @a ); die "git @a: $o" if $?; chomp $o; return $o }
sub commit { my ( $d, $m ) = @_; git( $d, 'add', '-A' ); git( $d, 'commit', '-q', '-m', $m ); return git( $d, 'rev-parse', 'HEAD' ) }

sub filing {
    my ( $id, $note ) = @_;
    return "---\nid: $id\ntitle: \"$id: a thing\"\nstatus: shipped\nstatus-note: \"$note\"\n---\n\n# Body\n\nSHIPPED (PENDING) in prose stays.\n";
}

my $d = tempdir( CLEANUP => 1 );
git( $d, 'init',   '-q',         '-b', 'main' );
git( $d, 'config', 'user.email', 't@example.invalid' );
git( $d, 'config', 'user.name',  't' );
make_path("$d/tools");
copy( "$root/$GEN",                  "$d/$GEN" )                  or die $!;
copy( "$root/tools/bump-version.pl", "$d/tools/bump-version.pl" ) or die $!;
spit( "$d/tools/import-field-practice.pl", "#!/usr/bin/perl\nexit 0;\n" );
spit( "$d/tools/gen-doc-index.pl",         "#!/usr/bin/perl\nexit 0;\n" );
spit( "$d/VERSION",                        "0.1.0\n" );
spit( "$d/NEXT_VERSION",                   "0.1.1\n" );
spit( "$d/docs/FEATURES.md",
    "---\nsubtitle: \"Everything - as of v0.1.0\"\n---\n\n# Timeline\n\nNewest first; releases are git tags.\n\n"
        . "- **0.1.0** (2026-01-01, edge) - **The first.** It began.\n" );
spit( "$d/docs/releases/CHANGELOG-archive.md",   "---\ntitle: \"Archive\"\n---\n" );
spit( "$d/docs/INDEX.md",                        "index\n" );
spit( "$d/starter/docs/ai-briefing-practice.md", "x\n" );
my $ABOUT = "---\ntitle: \"Changelog\"\n---\n\n";
my $OLD = "## 0.1.0 - EDGE: the first (2026-01-01)\n\n- SM1 (abcdef12) **the first thing.**\n";
spit( "$d/CHANGELOG.md", "$ABOUT## Unreleased\n\n$OLD" );
spit( "$d/docs/feature-requests/SM1-old.md", filing( 'SM1', 'SHIPPED (PENDING): released before this existed.' ) );
commit( $d, 'the first release' );
git( $d, 'tag', '-a', 'v0.1.0', '-m', 'v0.1.0' );

spit( "$d/CHANGELOG.md",
    "$ABOUT## Unreleased\n\n- SM2 (PENDING) **the second thing.**\n\n- SM3, SM4 (PENDING) **two at once.**\n\n"
        . "- a-label (PENDING) **no filing.**\n\n$OLD" );
spit( "$d/docs/feature-requests/SM2-second.md", filing( 'SM2', 'SHIPPED (PENDING): the second.' ) );
spit( "$d/docs/feature-requests/SM3-third.md", filing( 'SM3', 'SHIPPED (PENDING): the third.' ) );
spit( "$d/docs/feature-requests/SM4-fourth.md", filing( 'SM4', 'SHIPPED (PENDING): the fourth.' ) );
spit( "$d/docs/feature-requests/SM9-later.md", filing( 'SM9', 'SHIPPED (PENDING): lands later.' ) );
spit( "$d/docs/feature-requests/SM5-stamped.md", filing( 'SM5', 'SHIPPED (0.0.9): already said.' ) );
spit( "$d/docs/feature-requests/SM6-open.md",
    "---\nid: SM2\ntitle: \"not shipped\"\nstatus: candidate\nstatus-note: \"OPEN: nothing yet.\"\n---\n" );
commit( $d, 'the second and third' );

my $out = run_cmd( $^X, "$d/$GEN", '0.1.1', '--dir', $d, '--date', '2026-10-12' );
is( $? >> 8, 0, 'the generator writes, inside its allowlist' ) or diag $out;
like( $out, qr/filings: 3 status-note\(s\) stamped SHIPPED \(0\.1\.1\)/, 'and says how many filings it stamped' );

my %note = map {
    my ($n) = slurp("$d/docs/feature-requests/$_") =~ /^status-note: "([^"]*)"/m;
    ( $_ => $n // '' )
} qw(SM1-old.md SM2-second.md SM3-third.md SM4-fourth.md SM9-later.md SM5-stamped.md SM6-open.md);

is( $note{'SM2-second.md'}, 'SHIPPED (0.1.1): the second.', 'a filing whose id has an entry is stamped' );
is( $note{'SM3-third.md'},  'SHIPPED (0.1.1): the third.',  'every id an entry names' );
is( $note{'SM4-fourth.md'}, 'SHIPPED (0.1.1): the fourth.', '...the second of two' );
is( $note{'SM9-later.md'}, 'SHIPPED (PENDING): lands later.', 'one with no entry here is left for its release' );
is( $note{'SM1-old.md'}, 'SHIPPED (PENDING): released before this existed.',
    'one released in an earlier section is not stamped with this version' );
is( $note{'SM5-stamped.md'}, 'SHIPPED (0.0.9): already said.', 'one already stamped is left alone' );
is( $note{'SM6-open.md'}, 'OPEN: nothing yet.', 'one not shipped is left alone, whatever its id' );
like( slurp("$d/docs/feature-requests/SM2-second.md"), qr/SHIPPED \(PENDING\) in prose stays/,
    'only the status-note is touched' );

done_testing();
