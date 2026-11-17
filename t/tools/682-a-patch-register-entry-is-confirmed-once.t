#!/usr/bin/perl
# SM1454 R4: ONE BRANCH, ONE CONFIRMATION.
#
# A patch's fix, its docs/SECURITY.md register entry and its compliance stamps are one
# branch. The developer agent drafts the entry and says so - "awaiting the release
# manager's confirmation" - and the compliance check passes it below certified while
# naming it (it blocks a certified cut, which claims confirmed records, ADR 0010).
# After the release manager's ruling the developer agent runs ONE command,
# `tools/release.sh confirm-register SMNNNN --ruling N`, which rewrites the marker in
# every entry for that SM number to the confirmed wording and commits that one file
# on a new branch, claude/confirm-SMNNNN, cut from main in a worktree and held for
# vcs-review (SM1454 R6 d: an agent cannot commit on main). The branch is printed;
# that is what lands.
use strict;
use warnings;
use Test::More;
use File::Copy     qw(copy);
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use File::Temp     qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd);

my $root = repo_root();

sub spit {
    my ( $p, $t ) = @_;
    make_path( dirname($p) );
    open my $f, '>', $p or die "$p: $!";
    print {$f} $t;
    close $f;
}
sub slurp { open my $f, '<', $_[0] or return ''; local $/; my $t = <$f>; close $f; $t }
sub git { my ( $d, @a ) = @_; my $o = run_cmd( 'git', '-C', $d, @a ); die "git @a: $o" if $?; $o =~ s/^Devel::Cover:[^\n]*\n?//mg; chomp $o; $o }

my $DRAFT = <<'MD';
### 2026-11-20 - SM9001 (PENDING): a patch's entry

Assessment drafted by the developer agent (n836); awaiting the release manager's confirmation.

verdict : accepted, awaiting the release manager's confirmation. No trigger fired.

### 2026-11-20 - SM9001, SM9002 (0.1.1): the same patch, a second heading

Assessment drafted by the developer agent (n836); awaiting the release manager's confirmation.

### 2026-11-20 - SM90010 (PENDING): another number that starts with the same digits

Assessment drafted by the developer agent (n837); awaiting the release manager's confirmation.

### 2026-11-12 - SM9000 (PENDING): an earlier, confirmed entry

Assessment drafted by the developer agent (n824); confirmed by the release manager on 12 Nov 2026 (ruling 251).
MD

# A repository on main whose docs/SECURITY.md holds the entries above.
sub repo {
    my $d = tempdir( CLEANUP => 1 );
    git( $d, 'init',   '-q',         '-b', 'main' );
    git( $d, 'config', 'user.email', 't@example.invalid' );
    git( $d, 'config', 'user.name',  't' );
    make_path("$d/tools");
    copy( "$root/tools/$_", "$d/tools/$_" ) or die "$_: $!" for qw(release.sh confirm-register.pl);
    spit( "$d/docs/SECURITY.md", "# threat model\n\n## Significant-change assessments\n\n$DRAFT" );
    git( $d, 'add', '-A' );
    git( $d, 'commit', '-q', '-m', 'a patch branch landed' );
    return $d;
}

sub confirm {
    my ( $d, @a ) = @_;
    my $out = run_cmd( 'bash', "$d/tools/release.sh", 'confirm-register', @a );
    return ( $? >> 8, $out );
}

subtest 'the compliance check passes a drafted entry below certified, names it, and blocks a certified cut' => sub {
    my $scratch = tempdir( CLEANUP => 1 );
    my @needs   = (
        'tools/lazysite-compliance.pl', 'VERSION', 'CHANGELOG.md', 'docs/releases/CHANGELOG-archive.md',
        'docs/DECLARATION-OF-CONFORMITY.md', 'docs/SECURITY.md', 'docs/FEATURES.md', 'docs/RELIABILITY.md',
        'dist/config/bench-baseline.json', 'docs/compliance/OBLIGATIONS.md', 'docs/compliance/TECHNICAL-FILE.md',
        'docs/compliance/SIGNOFF.md',
    );
    for my $rel (@needs) {
        next unless -f "$root/$rel";
        make_path( dirname("$scratch/$rel") );
        copy( "$root/$rel", "$scratch/$rel" ) or die "copy $rel: $!";
    }
    # The real register may hold drafted entries awaiting confirmation (a patch's own, until
    # the manager confirms it); the base case is a register with none, so confirm them here.
    my $reg = slurp("$scratch/docs/SECURITY.md");
    $reg =~ s/awaiting the release manager's confirmation/confirmed by the release manager on 1 Jan 2026 (ruling 1)/g;
    spit( "$scratch/docs/SECURITY.md", $reg );
    my $run = sub { my $o = run_cmd( $^X, "$scratch/tools/lazysite-compliance.pl", '--check', '--channel', $_[0] ); return ( $? >> 8, $o ) };

    my ( $rc, $out ) = $run->('stable');
    is( $rc, 0, 'the tree as it stands passes a stable check' ) or return diag($out);
    unlike( $out, qr/awaiting the release manager/, 'and names no drafted entry' );

    spit( "$scratch/docs/SECURITY.md", slurp("$scratch/docs/SECURITY.md") . "\n$DRAFT" );
    ( $rc, $out ) = $run->('stable');
    is( $rc, 0, 'with drafted entries in the register, a stable check still passes' ) or diag($out);
    like( $out, qr/^  WARN significant-change register: 3 entries are drafted and awaiting the release manager's confirmation \(2026-11-20 - SM9001 \(PENDING\): a patch's entry; /m,
        'and names them, as an advisory' );
    like( $out, qr/: tools\/release\.sh confirm-register SMNNNN --ruling N \(blocking at certified\)$/m, 'with the command that confirms them' );
    unlike( $out, qr/SM9000 /, 'but not the confirmed one' );

    ( $rc, $out ) = $run->('certified');
    isnt( $rc, 0, 'a certified check does not' );
    like( $out, qr/^  FAIL significant-change register: 3 entries are drafted/m, 'it blocks on them' );
};

subtest 'confirm-register commits the confirmation on a new branch of main, and holds it' => sub {
    my $d = repo();
    spit( "$d/unrelated.txt", "x\n" );    # untracked: not committed with it
    my $main = git( $d, 'rev-parse', 'main' );
    my ( $rc, $out ) = confirm( $d, 'SM9001', '--ruling', '259', '--date', '2026-11-21', '--trailer', 'Assisted-by: Claude:test-model' );
    is( $rc, 0, 'confirmed' ) or return diag($out);
    like( $out, qr/SM9001 - 3 markers confirmed \(confirmed by the release manager on 21 Nov 2026 \(ruling 259\)\)/, 'saying how many' );
    like( $out, qr/^confirm-register: branch claude\/confirm-SM9001 at ([0-9a-f]{12}), held for vcs-review - land it$/m, 'and the branch to land' );
    is( git( $d, 'rev-parse', 'main' ), $main, 'main is as it was: nothing was committed on it' );
    is( git( $d, 'rev-parse', 'refs/vcs-review/hold/claude/confirm-SM9001' ), git( $d, 'rev-parse', 'claude/confirm-SM9001' ), 'the branch is held at its tip' );
    is( git( $d, 'rev-parse', 'claude/confirm-SM9001^' ), $main, 'it is cut from main, one commit' );

    my $t = git( $d, 'show', 'claude/confirm-SM9001:docs/SECURITY.md' ) . "\n";
    is( scalar( () = $t =~ /confirmed by the release manager on 21 Nov 2026 \(ruling 259\)/g ), 3, 'three markers on the branch are the confirmed wording' );
    is( scalar( () = $t =~ /awaiting the release manager's confirmation/g ), 1,
        'and the one left is SM90010\'s: a number that merely starts with the same digits is not named' );
    like( $t, qr/Assessment drafted by the developer agent \(n836\); confirmed by the release manager on 21 Nov 2026 \(ruling 259\)\./, 'in the wording every confirmed entry has' );
    like( $t, qr/verdict : accepted, confirmed by the release manager on 21 Nov 2026 \(ruling 259\)\. No trigger fired\./, 'the verdict line too' );
    like( $t, qr/\(n824\); confirmed by the release manager on 12 Nov 2026 \(ruling 251\)\./, 'an earlier entry is as it was' );
    like( slurp("$d/docs/SECURITY.md"), qr/awaiting the release manager's confirmation/, 'main\'s register still says awaiting' );
    my $msg = git( $d, 'log', '-1', '--format=%B', 'claude/confirm-SM9001' );
    like( $msg, qr/\ASM9001: register entry confirmed by the release manager \(ruling 259\)\n/, 'one commit says what it did' );
    like( $msg, qr/\nAssisted-by: Claude:test-model\n*\z/, 'with the trailers it was given' );
    is( git( $d, 'show', '--name-only', '--format=', 'claude/confirm-SM9001' ), 'docs/SECURITY.md', 'and holds that one file' );
    is( git( $d, 'status', '--porcelain' ), '?? unrelated.txt', 'the checkout was not touched' );
    unlike( git( $d, 'worktree', 'list' ), qr/wt-confirm/, 'and the worktree it used is gone' );
    ok( !-e "$d/tmp/wt-confirm-SM9001", 'from the disk too' );

    ( $rc, $out ) = confirm( $d, 'SM9001', '--ruling', '259' );
    is( $rc, 1, 'confirming it again is refused' ) or diag($out);
    like( $out, qr/branch claude\/confirm-SM9001 already exists/, 'saying why' );
};

subtest 'it works from a checkout on another branch with the register edited, and leaves both alone' => sub {
    my $d = repo();
    git( $d, 'checkout', '-q', '-b', 'a-branch' );
    my $edited = slurp("$d/docs/SECURITY.md") . "\nan uncommitted edit\n";
    spit( "$d/docs/SECURITY.md", $edited );
    my ( $rc, $out ) = confirm( $d, 'SM9002', '--ruling', '260', '--date', '2026-11-22' );
    is( $rc, 0, 'confirmed' ) or return diag($out);
    is( git( $d, 'rev-parse', '--abbrev-ref', 'HEAD' ), 'a-branch', 'the checkout is still on its branch' );
    is( slurp("$d/docs/SECURITY.md"), $edited, 'and its uncommitted edit is as it was' );
    my $t = git( $d, 'show', 'claude/confirm-SM9002:docs/SECURITY.md' );
    unlike( $t, qr/an uncommitted edit/, 'the branch is main\'s register, not the checkout\'s' );
    like( $t, qr/SM9001, SM9002 \(0\.1\.1\)[^\n]*\n\nAssessment drafted by the developer agent \(n836\); confirmed by the release manager on 22 Nov 2026 \(ruling 260\)/, 'with the entry confirmed' );
};

subtest 'confirm-register refuses, and changes nothing' => sub {
    my $d     = repo();
    my $head  = git( $d, 'rev-parse', 'HEAD' );
    my $text  = slurp("$d/docs/SECURITY.md");
    my %case = (
        'no ruling' => [ ['SM9001'], qr/--ruling N is needed/ ],
        'a bad date' => [ [ 'SM9001', '--ruling', '1', '--date', 'today' ], qr/--date wants YYYY-MM-DD/ ],
        'no SM number' => [ [ '--ruling', '1' ], qr/say which entry: SMNNNN/ ],
        'an unknown one' => [ [ 'SM1', '--ruling', '1' ], qr/no entry in docs\/SECURITY\.md names SM1/ ],
        'a confirmed one' => [ [ 'SM9000', '--ruling', '1' ], qr/already confirmed, or never drafted/ ],
    );
    for my $name ( sort keys %case ) {
        my ( $args, $want ) = @{ $case{$name} };
        my ( $rc,   $out )  = confirm( $d, @$args );
        isnt( $rc, 0, "$name: refused" );
        like( $out, $want, "$name: saying why" );
    }
    is( git( $d, 'rev-parse', 'HEAD' ), $head, 'no commit was made' );
    is( git( $d, 'branch', '--list', 'claude/*' ), '', 'no branch was made' );
    is( git( $d, 'for-each-ref', 'refs/vcs-review' ), '', 'no hold either' );
    is( slurp("$d/docs/SECURITY.md"),   $text, 'and the register is as it was' );

    make_path("$d/tmp/wt-confirm-SM9001");
    my ( $rc, $out ) = confirm( $d, 'SM9001', '--ruling', '1' );
    isnt( $rc, 0, 'its worktree path taken: refused' );
    like( $out, qr/tmp\/wt-confirm-SM9001 already exists/, 'saying so' );
    rmdir "$d/tmp/wt-confirm-SM9001";

    git( $d, 'branch', '-m', 'main', 'trunk' );
    ( $rc, $out ) = confirm( $d, 'SM9001', '--ruling', '1' );
    isnt( $rc, 0, 'a repository with no main: refused' );
    like( $out, qr/has no branch main/, 'saying so' );
};

done_testing();
