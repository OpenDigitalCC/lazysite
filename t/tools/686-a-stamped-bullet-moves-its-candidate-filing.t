#!/usr/bin/perl
# SM1454 R6 (b): A FILING WHOSE BULLET THE RELEASE STAMPS IS NOT A CANDIDATE ANY MORE.
#
# 0.17.1's second gate ran the full suite for 33 minutes and failed on one lint,
# t/lint/26: three filings (SM1454, SM1455, SM1456) were still `candidate` once the
# release material had stamped their CHANGELOG bullets with landed SHAs, and the
# lint calls a released claim on a `candidate` a lie. Marking them was a branch of its
# own. tools/release-material.pl now does it where it stamps the bullet: `candidate`
# becomes `shipped`, or `partial` when the bullet names a part (`SM1454 (R3)`), and the
# status-note is opened "SHIPPED (X.Y.Z): ", as P22 stamps a note a branch wrote as
# SHIPPED (PENDING) (t/tools/111).
#
# Reproduced on a scratch repository with three candidate filings, and the REAL
# t/lint/26 and t/lint/09 run on what the generator wrote, with no hand edit.
use strict;
use warnings;
use Test::More;
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd);

my $root = repo_root();

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
sub git { my ( $d, @a ) = @_; my $o = run_cmd( 'git', '-C', $d, @a ); die "git @a: $o" if $?; $o =~ s/^Devel::Cover:[^\n]*\n?//mg; chomp $o; return $o }
sub commit { my ( $d, $m ) = @_; git( $d, 'add', '-A' ); git( $d, 'commit', '-q', '-m', $m ); return git( $d, 'rev-parse', 'HEAD' ) }

sub filing {
    my ( $id, $status, $note ) = @_;
    return "---\nid: $id\ntitle: \"$id: a thing\"\nstatus: $status\n" . ( defined $note ? "status-note: \"$note\"\n" : '' ) . "---\n\n# Body\n";
}
sub field {
    my ( $d, $name, $key ) = @_;
    my ($v) = slurp("$d/docs/feature-requests/$name") =~ /^\Q$key\E:\s*"?(.*?)"?\s*$/m;
    return $v // '';
}

my $d = tempdir( CLEANUP => 1 );
git( $d, 'init',   '-q',         '-b', 'main' );
git( $d, 'config', 'user.email', 't@example.invalid' );
git( $d, 'config', 'user.name',  't' );
make_path("$d/tools");
copy( "$root/tools/$_", "$d/tools/$_" ) or die "$_: $!" for qw(release-material.pl bump-version.pl);
make_path("$d/t/lib");
make_path("$d/t/lint");
copy( "$root/t/lib/TestHelper.pm", "$d/t/lib/TestHelper.pm" ) or die $!;
for my $n (qw(09 26)) {
    my ($src) = glob "$root/t/lint/$n-*.t";
    ( my $base = $src ) =~ s{.*/}{};
    copy( $src, "$d/t/lint/$base" ) or die "$src: $!";
}
spit( "$d/lazysite-processor.pl",          "# the root marker\n" );
spit( "$d/tools/import-field-practice.pl", "#!/usr/bin/perl\nexit 0;\n" );
spit( "$d/tools/gen-doc-index.pl",         "#!/usr/bin/perl\nexit 0;\n" );
spit( "$d/VERSION",                        "0.1.0\n" );
spit( "$d/NEXT_VERSION",                   "0.1.1\n" );
spit( "$d/docs/FEATURES.md", "---\nsubtitle: \"Everything - as of v0.1.0\"\n---\n\nNewest first; releases are git tags.\n\n- **0.1.0** (2026-01-01, stable) - **The first.** It began.\n" );
spit( "$d/docs/releases/CHANGELOG-archive.md", "---\ntitle: \"Archive\"\n---\n\n" );
spit( "$d/docs/INDEX.md",                      "index\n" );
spit( "$d/starter/lazysite/templates/docs/ai-briefing-practice.md", "x\n" );

# t/lint/09 wants a corpus of at least 60 filings; fillers say nothing of any release.
spit( sprintf( "%s/docs/feature-requests/SM%d-filler.md", $d, 100 + $_ ), filing( 'SM' . ( 100 + $_ ), 'candidate', 'OPEN: not yet.' ) ) for 1 .. 60;
my $PRE = "---\ntitle: \"Changelog\"\n---\n\nShipped versus mentioned\n: An item that SHIPPED begins its own bullet and names the commit.\n\n";
spit( "$d/CHANGELOG.md", "$PRE## Unreleased\n\n## 0.1.0 - STABLE: the first (2026-01-01)\n\n- SM1 (abcdef12) **the first thing.**\n" );
spit( "$d/docs/feature-requests/SM1-old.md", filing( 'SM1', 'shipped', 'SHIPPED (0.1.0): the first.' ) );
commit( $d, 'the first release' );
git( $d, 'tag', '-a', 'v0.1.0', '-m', 'v0.1.0' );

# The 0.17.1 shape: three candidate filings, each with a PENDING bullet, one of them a
# part of a larger filing; and the filings that must be left alone.
spit( "$d/CHANGELOG.md", $PRE . <<'C' . "## 0.1.0 - STABLE: the first (2026-01-01)\n\n- SM1 (abcdef12) **the first thing.**\n" );
## Unreleased

- SM11 (PENDING) **a plain fix.**

- SM12, SM13 (PENDING) **two at once.**

- SM14 (R1, R2) (PENDING) **two parts of a larger filing.**

- SM15 partial (PENDING) **a part, in words.**

- SM16 (PENDING) **a note written for the release.**

- SM18 (PENDING) **an already shipped one.**

C
spit( "$d/docs/feature-requests/SM11-plain.md",   filing( 'SM11', 'candidate', 'OPEN. Target 0.1.1 stable. One line in the wrapper and a test.' ) );
spit( "$d/docs/feature-requests/SM12-two.md",     filing( 'SM12', 'candidate', 'OPEN: the first of two.' ) );
spit( "$d/docs/feature-requests/SM13-two.md",     filing( 'SM13', 'candidate' ) );
spit( "$d/docs/feature-requests/SM14-part.md",    filing( 'SM14', 'candidate', 'OPEN. R1 and R2 built; R3 is not built.' ) );
spit( "$d/docs/feature-requests/SM15-words.md",   filing( 'SM15', 'candidate', 'OPEN: half done.' ) );
spit( "$d/docs/feature-requests/SM16-written.md", filing( 'SM16', 'candidate', 'SHIPPED (PENDING): written on the branch.' ) );
spit( "$d/docs/feature-requests/SM17-parked.md",  filing( 'SM17', 'parked',    'Parked: waits for a ruling.' ) );
spit( "$d/docs/feature-requests/SM18-done.md",    filing( 'SM18', 'shipped',   'SHIPPED (PENDING): done on the branch.' ) );
spit( "$d/docs/feature-requests/SM19-none.md",    filing( 'SM19', 'candidate', 'OPEN: no bullet names it.' ) );
commit( $d, 'the candidates and their bullets' );

my $out = run_cmd( $^X, "$d/tools/release-material.pl", '0.1.1', '--dir', $d, '--date', '2026-02-02' );
is( $? >> 8, 0, 'the generator writes' ) or diag $out;
like( $out, qr/^release-material: filings: 2 status-note\(s\) stamped SHIPPED \(0\.1\.1\)$/m, 'two PENDING notes stamped, as P22 says' );
like( $out, qr/^release-material: filings: 6 candidate\(s\) moved to shipped or partial$/m, 'and six candidates moved' );

my %want = (
    'SM11-plain.md'   => [ 'shipped', 'SHIPPED (0.1.1): One line in the wrapper and a test.' ],
    'SM12-two.md'     => [ 'shipped', 'SHIPPED (0.1.1): the first of two.' ],
    'SM13-two.md'     => [ 'shipped', 'SHIPPED (0.1.1).' ],
    'SM14-part.md'    => [ 'partial', 'PARTIALLY SHIPPED (0.1.1): R1 and R2 built; R3 is not built.' ],
    'SM15-words.md'   => [ 'partial', 'PARTIALLY SHIPPED (0.1.1): half done.' ],
    'SM16-written.md' => [ 'shipped', 'SHIPPED (0.1.1): written on the branch.' ],
    'SM17-parked.md'  => [ 'parked',  'Parked: waits for a ruling.' ],
    'SM18-done.md'    => [ 'shipped', 'SHIPPED (0.1.1): done on the branch.' ],
    'SM19-none.md'    => [ 'candidate', 'OPEN: no bullet names it.' ],
);
for my $name ( sort keys %want ) {
    is( field( $d, $name, 'status' ),      $want{$name}[0], "$name: status $want{$name}[0]" );
    is( field( $d, $name, 'status-note' ), $want{$name}[1], "$name: its note" );
}
is( field( $d, 'SM13-two.md', 'status-note' ), 'SHIPPED (0.1.1).', 'a candidate with no note gets one' );
like( slurp("$d/docs/feature-requests/SM13-two.md"), qr/^status: shipped\nstatus-note: "SHIPPED \(0\.1\.1\)\."\n---/m, 'next to its status' );

# The lints, on what the generator wrote, with no hand edit.
sub lint {
    my ($n) = @_;
    my ($t) = glob "$d/t/lint/$n-*.t";
    my $o = run_cmd( $^X, '-I', "$d/t/lib", $t );
    return ( $? >> 8, $o );
}
git( $d, 'add', '-A' );
git( $d, 'commit', '-q', '-m', 'the release material' );
my ( $rc, $lint ) = lint('26');
is( $rc, 0, 't/lint/26 passes on the stamped stage' ) or diag $lint;
( $rc, $lint ) = lint('09');
is( $rc, 0, 't/lint/09 passes on it' ) or diag $lint;

# The control: the lint does see the fault this prevents.
my $path = "$d/docs/feature-requests/SM11-plain.md";
my $kept = slurp($path);
( my $back = $kept ) =~ s/^status: shipped$/status: candidate/m or die;
spit( $path, $back );
( $rc, $lint ) = lint('26');
isnt( $rc, 0, 'with SM11 put back to candidate, t/lint/26 fails' );
like( $lint, qr/SM11 is 'candidate' but shipped in 0\.1\.1/, 'saying which' );
spit( $path, $kept );

done_testing();
