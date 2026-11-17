#!/usr/bin/perl
# SM1454 R7 (ruling 262): AN EDGE OR BETA PATCH'S RECORDS ARE WRITTEN BY THE RELEASE TOO.
#
# R6 (a) stamped the two compliance records only for a stable patch; an edge or beta cut
# said "walk them by hand". 0.17.2 is an edge patch of 0.17.1, and its gate stopped at the
# compliance check (records at 0.17.1, cutting 0.17.2). Every 0.16 edge and beta cut was
# walked by hand, the same mechanical walk a stable patch gets. tools/release-material.pl
# compliance() now stamps a patch (Z > 0) on the edge and beta channels as it does on
# stable, and the clause says the channel truthfully ("an **edge patch**"). The same
# refusals stand (a runtime change with no register entry; records not walked at the base).
# A new minor and a certified cut stay with the hand walk.
#
# Each subtest fails against the code before R7: an edge or beta patch said nothing about
# the records and left them at the base, so the generator's output has no "patch-walked"
# line, the compliance check refuses, and "an edge patch" is never written.
#
# Driven through the real generator and the real compliance check on a scratch repository.
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

my $BASE_SEC = "# Security\n\n### 2026-01-01 - SM1 (0.1.0): the first entry\n\nAssessment drafted by the developer agent; confirmed by the release manager on 1 Jan 2026 (ruling 1).\n";
my $ENTRY = "### 2026-02-01 - SM2 (PENDING): the auth wrapper reads the path\n\nAssessment drafted by the developer agent (n1); awaiting the release manager's confirmation.\n";

# A repository whose v0.1.0 (tagged on $o{base_channel}, which the tag does not record)
# has both records walked at 0.1.0, and whose main carries a runtime change, its register
# entry and its CHANGELOG entry on top of it.
sub repo {
    my (%o) = @_;
    my $at = $o{at} // '0.1.0';
    my $d = tempdir( CLEANUP => 1 );
    git( $d, 'init',   '-q',         '-b', 'main' );
    git( $d, 'config', 'user.email', 't@example.invalid' );
    git( $d, 'config', 'user.name',  't' );
    make_path("$d/tools");
    copy( "$root/tools/$_", "$d/tools/$_" ) or die "$_: $!" for qw(release-material.pl bump-version.pl lazysite-compliance.pl);
    spit( "$d/tools/import-field-practice.pl", "#!/usr/bin/perl\nexit 0;\n" );
    spit( "$d/tools/gen-doc-index.pl",         "#!/usr/bin/perl\nexit 0;\n" );
    spit( "$d/VERSION",                        "0.1.0\n" );
    spit( "$d/NEXT_VERSION",                   "0.1.1\n" );
    spit( "$d/docs/FEATURES.md", "---\nsubtitle: \"Everything - as of v0.1.0\"\n---\n\nNewest first; releases are git tags.\n\n- **0.1.0** (2026-01-01, edge) - **The first.** It began.\n" );
    spit( "$d/docs/releases/CHANGELOG-archive.md", "---\ntitle: \"Archive\"\n---\n\n" );
    spit( "$d/docs/INDEX.md",                      "index\n" );
    spit( "$d/starter/lazysite/templates/docs/ai-briefing-practice.md", "x\n" );
    spit( "$d/dist/config/classification.json", <<'J' );
{"exclude":["^tools/","^t/","^docs/","^dist/","^CHANGELOG\\.md$","^VERSION$","^NEXT_VERSION$","^starter/lazysite/templates/docs/"],
 "rules":[{"pattern":"^lazysite-[a-z]+\\.pl$","bucket":"code","install_to":null},{"pattern":"^lib/.*\\.pm$","bucket":"code","install_to":null}]}
J
    spit( "$d/docs/SECURITY.md", $BASE_SEC );
    spit( "$d/docs/compliance/OBLIGATIONS.md", <<"M" );
---
title: "Obligations"
---

# The register

```yaml
reviewed_at_version: $at
content_sha:         c8547d3d824105d1
reviewed_on:         2026-01-01
next_review:         at the next release
```

# Walked for 0.1.0: what a person must confirm

Walked on 2026-01-01.
M
    spit( "$d/docs/compliance/TECHNICAL-FILE.md", <<"M" );
---
title: "Technical file"
---

```yaml
status:              index - complete in coverage, walked row by row on 2026-01-01 against the 0.1.0 edge
covers_version:      $at
content_sha:         148b3776ec692b5c
```
M
    spit( "$d/lazysite-auth.pl", "print 1;\n" );
    spit( "$d/CHANGELOG.md", "## Unreleased\n\n## 0.1.0 - EDGE: the first (2026-01-01)\n\n- SM1 (abcdef12) **the first thing.**\n" );
    commit( $d, 'the first release' );
    git( $d, 'tag', '-a', 'v0.1.0', '-m', 'v0.1.0' );

    my %change = (
        'lazysite-auth.pl' => "print 2;\n",
        'docs/SECURITY.md' => "$BASE_SEC\n$ENTRY",
        'CHANGELOG.md' => "## Unreleased\n\n- SM2 (PENDING) **the auth wrapper reads the path.**\n\n## 0.1.0 - EDGE: the first (2026-01-01)\n\n- SM1 (abcdef12) **the first thing.**\n",
        %{ $o{change} // {} },
    );
    delete $change{$_} for grep { !defined $change{$_} } keys %change;
    spit( "$d/$_", $change{$_} ) for keys %change;
    commit( $d, 'SM2' );
    return $d;
}

sub gen {
    my ( $d, $version, @a ) = @_;
    my $out = run_cmd( $^X, "$d/tools/release-material.pl", $version, '--dir', $d, '--date', '2026-02-02', @a );
    return ( $? >> 8, $out );
}
sub compliance {
    my ( $d, $channel ) = @_;
    my $out = run_cmd( $^X, "$d/tools/lazysite-compliance.pl", '--check', '--channel', $channel );
    return ( $? >> 8, $out );
}

subtest 'an edge patch with a register entry is stamped, and the compliance check then passes on edge' => sub {
    my $before = repo();
    git( $before, 'checkout', '-q', '-b', 'unstamped' );
    spit( "$before/VERSION", "0.1.1\n" );
    my ( $rc, $out ) = compliance( $before, 'edge' );
    isnt( $rc, 0, 'unstamped, the compliance check refuses 0.1.1 on edge' );
    like( $out, qr/FAIL obligations register: reviewed_at_version is 0\.1\.0, cutting 0\.1\.1 - walk /, 'naming the register' );

    my $d = repo();
    ( $rc, $out ) = gen( $d, '0.1.1', '--channel', 'edge' );
    is( $rc, 0, 'the generator writes' ) or return diag($out);
    like( $out, qr/^release-material: compliance: patch-walked OBLIGATIONS\.md and TECHNICAL-FILE\.md for 0\.1\.1 against v0\.1\.0 \(1 runtime file, 1 register entry\)$/m, 'and says what it walked' );

    my $obl = slurp("$d/docs/compliance/OBLIGATIONS.md");
    like( $obl, qr/^reviewed_at_version: 0\.1\.1$/m,       'OBLIGATIONS.md says 0.1.1' );
    like( $obl, qr/^reviewed_on:         2026-02-02$/m,    'and the date' );
    like( $obl, qr/^# Walked for 0\.1\.1: what a person must confirm\n\nPatch-walked on 2026-02-02 by tools\/release-material\.pl for 0\.1\.1, an \*\*edge patch\*\* of 0\.1\.0,/m, 'the clause says an edge patch, not a stable one' );
    unlike( $obl, qr/stable patch/, 'and never calls it stable' );
    like( $obl, qr/Runtime files it changes: `lazysite-auth\.pl`\.\nRegister entries it carries: 2026-02-01 - SM2 \(PENDING\)/, 'naming the runtime file and the register entry' );
    like( slurp("$d/docs/compliance/TECHNICAL-FILE.md"),
        qr/^status:\s+index - complete in coverage, patch-walked on 2026-02-02 against 0\.1\.1, an edge patch of 0\.1\.0 \(the diff from v0\.1\.0: runtime files: lazysite-auth\.pl; register entries: 2026-02-01 - SM2 \(PENDING\)[^)]*\); walked row by row /m,
        'and the technical file carries it in its status' );
    like( slurp("$d/docs/compliance/TECHNICAL-FILE.md"), qr/^covers_version:      0\.1\.1$/m, 'covers_version says 0.1.1' );

    git( $d, 'add', '-A' );
    git( $d, 'commit', '-q', '-m', 'the release material' );
    ( $rc, $out ) = compliance( $d, 'edge' );
    is( $rc, 0, 'the compliance check passes the stamped records on edge' ) or diag($out);
    like( $out, qr/ok   obligations register reviewed at 0\.1\.1 /, 'reading the register as reviewed at 0.1.1' );
};

subtest 'a beta patch is stamped, and the clause says beta' => sub {
    my $d = repo();
    my ( $rc, $out ) = gen( $d, '0.1.1', '--channel', 'beta' );
    is( $rc, 0, 'the generator writes' ) or return diag($out);
    like( $out, qr/compliance: patch-walked OBLIGATIONS\.md and TECHNICAL-FILE\.md for 0\.1\.1 against v0\.1\.0/, 'and says it walked' );
    my $obl = slurp("$d/docs/compliance/OBLIGATIONS.md");
    like( $obl, qr/^reviewed_at_version: 0\.1\.1$/m, 'OBLIGATIONS.md says 0.1.1' );
    like( $obl, qr/for 0\.1\.1, a \*\*beta patch\*\* of 0\.1\.0,/, 'a beta patch' );
    like( slurp("$d/docs/compliance/TECHNICAL-FILE.md"), qr/against 0\.1\.1, a beta patch of 0\.1\.0 \(/, 'in the status too' );
    git( $d, 'add', '-A' );
    git( $d, 'commit', '-q', '-m', 'the release material' );
    ( $rc, $out ) = compliance( $d, 'beta' );
    is( $rc, 0, 'the compliance check passes on beta' ) or diag($out);
};

subtest 'an edge patch with a runtime change and no register entry is refused' => sub {
    my $d = repo( change => { 'docs/SECURITY.md' => undef } );
    my ( $rc, $out ) = gen( $d, '0.1.1', '--channel', 'edge' );
    is( $rc, 1, 'refused' );
    like( $out, qr/REFUSED - a runtime file changed since v0\.1\.0 and the diff adds no entry to the significant-change register .*: lazysite-auth\.pl\./s, 'naming the file' );
    like( slurp("$d/docs/compliance/OBLIGATIONS.md"), qr/^reviewed_at_version: 0\.1\.0$/m, 'the records are as they were' );

    $d = repo( at => '0.0.9' );
    ( $rc, $out ) = gen( $d, '0.1.1', '--channel', 'edge' );
    is( $rc, 1, 'records not walked at the base: refused' );
    like( $out, qr/says reviewed_at_version 0\.0\.9, not 0\.1\.0, the release this patch is of: it was not walked at the base/, 'naming the record and the base' );
};

subtest 'an edge minor, and a certified patch, are left to the hand walk' => sub {
    my %case = (
        'an edge minor'     => [ '0.2.0', 'edge',      qr/this cut is a new minor: walk them by hand/ ],
        'a beta minor'      => [ '0.2.0', 'beta',      qr/this cut is a new minor: walk them by hand/ ],
        'a certified patch' => [ '0.1.1', 'certified', qr/this cut is a certified cut: walk them by hand/ ],
    );
    for my $name ( sort keys %case ) {
        my ( $v, $channel, $say ) = @{ $case{$name} };
        my $d = repo();
        my ( $rc, $out ) = gen( $d, $v, '--channel', $channel );
        is( $rc, 0, "$name: the generator writes the rest" ) or diag($out);
        like( $out, $say, "$name: and says the records need a hand walk" );
        like( slurp("$d/docs/compliance/OBLIGATIONS.md"), qr/^reviewed_at_version: 0\.1\.0$/m, "$name: OBLIGATIONS.md is as it was" );
        like( slurp("$d/docs/compliance/TECHNICAL-FILE.md"), qr/^covers_version:      0\.1\.0$/m, "$name: and TECHNICAL-FILE.md" );
    }
};

subtest 'an edge patch of a base cut on another channel is stamped from the base all the same' => sub {
    # 0.1.2 on edge, the line's newest tag v0.1.1 (whatever channel): walked at 0.1.1.
    my $d = repo();
    for my $f (qw(OBLIGATIONS TECHNICAL-FILE)) {
        my $t = slurp("$d/docs/compliance/$f.md");
        $t =~ s/^((?:reviewed_at|covers)_version:\s+)0\.1\.0$/${1}0.1.1/m or die;
        spit( "$d/docs/compliance/$f.md", $t );
    }
    commit( $d, 'walked for 0.1.1' );
    git( $d, 'tag', '-a', 'v0.1.1', '-m', 'v0.1.1' );
    spit( "$d/lazysite-auth.pl", "print 3;\n" );
    spit( "$d/CHANGELOG.md", "## Unreleased\n\n- SM3 (PENDING) **a second change.**\n\n## 0.1.1 - EDGE: the second (2026-01-15)\n\n- SM2 (abcdef34) **the auth wrapper reads the path.**\n\n## 0.1.0 - EDGE: the first (2026-01-01)\n\n- SM1 (abcdef12) **the first thing.**\n" );
    spit( "$d/docs/SECURITY.md", slurp("$d/docs/SECURITY.md") . "\n### 2026-02-05 - SM3 (PENDING): a second change\n\nAssessment drafted by the developer agent (n2); awaiting the release manager's confirmation.\n" );
    commit( $d, 'SM3' );
    my ( $rc, $out ) = gen( $d, '0.1.2', '--channel', 'edge' );
    is( $rc, 0, 'the generator writes' ) or return diag($out);
    like( $out, qr/patch-walked .* for 0\.1\.2 against v0\.1\.1 \(1 runtime file, 1 register entry\)/, 'the base is v0.1.1' );
    like( slurp("$d/docs/compliance/OBLIGATIONS.md"), qr/^reviewed_at_version: 0\.1\.2$/m, 'and the records say 0.1.2' );
};

done_testing();
