#!/usr/bin/perl
# SM1454 R4: ONE BRANCH, ONE CONFIRMATION.
#
# A patch's fix, its docs/SECURITY.md register entry and its compliance stamps are one
# branch. The developer agent drafts the entry and says so - "awaiting the release
# manager's confirmation" - and the compliance check passes it below certified while
# naming it (it blocks a certified cut, which claims confirmed records, ADR 0010).
# The release manager lands the branch and runs ONE command on main,
# `tools/release.sh confirm-register SMNNNN --ruling N`, which rewrites the marker in
# every entry for that SM number to the confirmed wording and commits that one file.
# There is no second branch round.
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

subtest 'confirm-register rewrites the marker in each entry for the number, and commits that one file' => sub {
    my $d = repo();
    spit( "$d/unrelated.txt", "x\n" );    # untracked: not committed with it
    my ( $rc, $out ) = confirm( $d, 'SM9001', '--ruling', '259', '--date', '2026-11-21' );
    is( $rc, 0, 'confirmed' ) or return diag($out);
    like( $out, qr/SM9001 - 3 markers confirmed \(confirmed by the release manager on 21 Nov 2026 \(ruling 259\)\), committed [0-9a-f]{12}/, 'saying how many and where' );
    my $t = slurp("$d/docs/SECURITY.md");
    is( scalar( () = $t =~ /confirmed by the release manager on 21 Nov 2026 \(ruling 259\)/g ), 3, 'three markers are the confirmed wording' );
    is( scalar( () = $t =~ /awaiting the release manager's confirmation/g ), 1,
        'and the one left is SM90010\'s: a number that merely starts with the same digits is not named' );
    like( $t, qr/Assessment drafted by the developer agent \(n836\); confirmed by the release manager on 21 Nov 2026 \(ruling 259\)\./, 'in the wording every confirmed entry has' );
    like( $t, qr/verdict : accepted, confirmed by the release manager on 21 Nov 2026 \(ruling 259\)\. No trigger fired\./, 'the verdict line too' );
    like( $t, qr/\(n824\); confirmed by the release manager on 12 Nov 2026 \(ruling 251\)\./, 'an earlier entry is as it was' );
    is( git( $d, 'log', '-1', '--format=%s' ), 'SM9001: register entry confirmed by the release manager (ruling 259)', 'one commit says what it did' );
    is( git( $d, 'show', '--name-only', '--format=', 'HEAD' ), 'docs/SECURITY.md', 'and holds that one file' );
    is( git( $d, 'status', '--porcelain' ), '?? unrelated.txt', 'nothing else was touched' );

    ( $rc, $out ) = confirm( $d, 'SM9001', '--ruling', '259' );
    is( $rc, 1, 'confirming it again is refused' ) or diag($out);
    like( $out, qr/nothing "awaiting the release manager's confirmation" - already confirmed, or never drafted/, 'saying why' );
};

subtest 'confirm-register refuses, and changes nothing' => sub {
    my $d    = repo();
    my $head = git( $d, 'rev-parse', 'HEAD' );
    my $text = slurp("$d/docs/SECURITY.md");
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
    is( slurp("$d/docs/SECURITY.md"),   $text, 'and the register is as it was' );

    spit( "$d/docs/SECURITY.md", "$text\nan edit\n" );
    my ( $rc, $out ) = confirm( $d, 'SM9001', '--ruling', '1' );
    isnt( $rc, 0, 'uncommitted changes to the register: refused' );
    like( $out, qr/docs\/SECURITY\.md has uncommitted changes/, 'saying so' );
    git( $d, 'checkout', '-q', 'docs/SECURITY.md' );

    git( $d, 'checkout', '-q', '-b', 'a-branch' );
    ( $rc, $out ) = confirm( $d, 'SM9001', '--ruling', '1' );
    isnt( $rc, 0, 'off main: refused' );
    like( $out, qr/run it on main - .* is on 'a-branch'/, 'saying where it is' );
};

done_testing();
