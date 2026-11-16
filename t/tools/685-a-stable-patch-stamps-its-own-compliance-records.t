#!/usr/bin/perl
# SM1454 R6 (a): A STABLE PATCH'S COMPLIANCE RECORDS ARE STAMPED BY THE RELEASE.
#
# 0.17.1 was one line in the auth wrapper. Its gate stopped in ten seconds at the
# compliance check - OBLIGATIONS.md (reviewed_at_version) and TECHNICAL-FILE.md
# (covers_version) still said 0.17.0 - and the walk was a branch of its own, landed
# before the gate could start again (SM1456). tools/release-material.pl, which the
# gate's stage and the build's release commit both run, now does the patch walk: for a
# stable patch of a release at which both records were walked, it stamps the target
# and prepends a dated clause naming the diff's RUNTIME files (dist/config/
# classification.json decides) and the register entries it carries. It refuses a
# runtime change with no register entry, and a record that was not walked at the base;
# a minor or certified cut, and edge and beta, are left for the compliance check.
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

# A repository whose v0.1.0 has both records walked at 0.1.0, and whose main carries
# %change on top of it (path => text). The CHANGELOG entry is SM2.
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
    spit( "$d/docs/FEATURES.md", "---\nsubtitle: \"Everything - as of v0.1.0\"\n---\n\nNewest first; releases are git tags.\n\n- **0.1.0** (2026-01-01, stable) - **The first.** It began.\n" );
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
status:              index - complete in coverage, walked row by row on 2026-01-01 against the 0.1.0 stable
covers_version:      $at
content_sha:         148b3776ec692b5c
```
M
    spit( "$d/lazysite-auth.pl", "print 1;\n" );
    spit( "$d/CHANGELOG.md", "## Unreleased\n\n## 0.1.0 - STABLE: the first (2026-01-01)\n\n- SM1 (abcdef12) **the first thing.**\n" );
    commit( $d, 'the first release' );
    git( $d, 'tag', '-a', 'v0.1.0', '-m', 'v0.1.0' );

    my %change = (
        'lazysite-auth.pl'      => "print 2;\n",
        'tools/some-tool.pl'    => "# a release tool\n",
        'docs/SECURITY.md'      => "$BASE_SEC\n$ENTRY",
        'CHANGELOG.md' => "## Unreleased\n\n- SM2 (PENDING) **the auth wrapper reads the path.**\n\n## 0.1.0 - STABLE: the first (2026-01-01)\n\n- SM1 (abcdef12) **the first thing.**\n",
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

subtest 'a stable patch of a walked release: the records are stamped, and the compliance check agrees' => sub {
    my $d = repo();

    # The 0.17.1 gate's first stop: the records say the base's version.
    my $before = repo();
    git( $before, 'checkout', '-q', '-b', 'unstamped' );
    spit( "$before/VERSION", "0.1.1\n" );
    my ( $rc, $out ) = compliance( $before, 'stable' );
    isnt( $rc, 0, 'unstamped, the compliance check refuses 0.1.1' );
    like( $out, qr/FAIL obligations register: reviewed_at_version is 0\.1\.0, cutting 0\.1\.1 - walk /, 'naming the register' );

    ( $rc, $out ) = gen( $d, '0.1.1', '--channel', 'stable' );
    is( $rc, 0, 'the generator writes' ) or return diag($out);
    like( $out, qr/^release-material: compliance: patch-walked OBLIGATIONS\.md and TECHNICAL-FILE\.md for 0\.1\.1 against v0\.1\.0 \(1 runtime file, 1 register entry\)$/m, 'and says what it walked' );

    my $obl = slurp("$d/docs/compliance/OBLIGATIONS.md");
    like( $obl, qr/^reviewed_at_version: 0\.1\.1$/m, 'OBLIGATIONS.md says 0.1.1' );
    like( $obl, qr/^reviewed_on:         2026-02-02$/m, 'and the date' );
    like( $obl, qr/^content_sha:         c8547d3d824105d1$/m, 'the hash line is left alone' );
    my ($clause) = $obl =~ /(# Walked for 0\.1\.1: what a person must confirm\n.*?)\n# Walked for 0\.1\.0/s;
    ok( defined $clause, 'a section for 0.1.1 sits above the one for 0.1.0' ) or diag($obl);
    like( $clause // '', qr/Patch-walked on 2026-02-02 by tools\/release-material\.pl for 0\.1\.1, a \*\*stable patch\*\* of 0\.1\.0/, 'dated, and naming the base' );
    like( $clause // '', qr/Runtime files it changes: `lazysite-auth\.pl`\./, 'the runtime file the diff changes' );
    unlike( $clause // '', qr/some-tool|CHANGELOG/, 'and not the tooling or the documents' );
    like( $clause // '', qr/Register entries it carries: 2026-02-01 - SM2 \(PENDING\): the auth wrapper reads the path\./, 'the register entry it carries' );

    my $tf = slurp("$d/docs/compliance/TECHNICAL-FILE.md");
    like( $tf, qr/^covers_version:      0\.1\.1$/m, 'TECHNICAL-FILE.md says 0.1.1' );
    like( $tf, qr/^status:\s+index - complete in coverage, patch-walked on 2026-02-02 against 0\.1\.1, a stable patch of 0\.1\.0 \(the diff from v0\.1\.0: runtime files: lazysite-auth\.pl; register entries: 2026-02-01 - SM2 \(PENDING\): the auth wrapper reads the path\); walked row by row on 2026-01-01 /m,
        'its status carries the clause, ahead of the walk it follows' );

    git( $d, 'add', '-A' );
    git( $d, 'commit', '-q', '-m', 'the release material' );
    ( $rc, $out ) = compliance( $d, 'stable' );
    is( $rc, 0, 'the compliance check passes the stamped records' ) or diag($out);
    like( $out, qr/ok   obligations register reviewed at 0\.1\.1 \(content changed/, 'reading the register as reviewed at 0.1.1' );
};

subtest 'a patch that changes nothing a site runs says so' => sub {
    my $d = repo( change => { 'lazysite-auth.pl' => undef, 'docs/SECURITY.md' => undef } );
    my ( $rc, $out ) = gen( $d, '0.1.1', '--channel', 'stable' );
    is( $rc, 0, 'needs no register entry' ) or return diag($out);
    like( slurp("$d/docs/compliance/OBLIGATIONS.md"), qr/Runtime files it changes: none - the diff changes nothing a site runs\.\nRegister entries it carries: none\./, 'the clause says none and none' );
    like( slurp("$d/docs/compliance/TECHNICAL-FILE.md"), qr/the diff from v0\.1\.0: runtime files: none; register entries: none\)/, 'in the status too' );
    like( $out, qr/\(0 runtime files, 0 register entries\)/, 'and in the output' );
};

subtest 'it refuses, and says why' => sub {
    my $d = repo( change => { 'docs/SECURITY.md' => undef } );
    my ( $rc, $out ) = gen( $d, '0.1.1', '--channel', 'stable' );
    is( $rc, 1, 'a runtime file changed and the diff adds no register entry: refused' );
    like( $out, qr/REFUSED - a runtime file changed since v0\.1\.0 and the diff adds no entry to the significant-change register .*: lazysite-auth\.pl\./s, 'naming the file' );
    like( slurp("$d/docs/compliance/OBLIGATIONS.md"), qr/^reviewed_at_version: 0\.1\.0$/m, 'the records are as they were' );

    $d = repo( change => { 'docs/SECURITY.md' => "$BASE_SEC\n### 2026-02-01 - a thing with no number\n\nAssessment.\n" } );
    ( $rc, $out ) = gen( $d, '0.1.1', '--channel', 'stable' );
    is( $rc, 1, 'a register entry that names no SM number does not count' );
    like( $out, qr/adds no entry to the significant-change register/, 'saying so' );

    $d = repo( at => '0.0.9' );
    ( $rc, $out ) = gen( $d, '0.1.1', '--channel', 'stable' );
    is( $rc, 1, 'records walked at an earlier release than the base: refused' );
    like( $out, qr/REFUSED - docs\/compliance\/OBLIGATIONS\.md says reviewed_at_version 0\.0\.9, not 0\.1\.0, the release this patch is of: it was not walked at the base/, 'naming the record and the base' );
    like( slurp("$d/docs/compliance/TECHNICAL-FILE.md"), qr/^covers_version:      0\.0\.9$/m, 'and nothing was stamped' );
};

subtest 'a minor, a certified cut, edge, beta and a hand walk are left alone' => sub {
    my %case = (
        'a new minor' => [ '0.2.0', [ '--channel', 'stable' ],    qr/this cut is a new minor: walk them by hand/ ],
        'certified'   => [ '0.1.1', [ '--channel', 'certified' ], qr/this cut is a certified cut: walk them by hand/ ],
    );
    for my $name ( sort keys %case ) {
        my ( $v, $args, $say ) = @{ $case{$name} };
        my $d = repo();
        my ( $rc, $out ) = gen( $d, $v, @$args );
        is( $rc, 0, "$name: the generator writes the rest" ) or diag($out);
        like( $out, $say, "$name: and says the records need a hand walk" );
        like( slurp("$d/docs/compliance/OBLIGATIONS.md"), qr/^reviewed_at_version: 0\.1\.0$/m, "$name: OBLIGATIONS.md is as it was" );
        like( slurp("$d/docs/compliance/TECHNICAL-FILE.md"), qr/^covers_version:      0\.1\.0$/m, "$name: and TECHNICAL-FILE.md" );
        unlike( slurp("$d/docs/compliance/OBLIGATIONS.md"), qr/Walked for \Q$v\E/, "$name: no clause" );
    }
    for my $channel (qw(edge beta)) {
        my $d = repo();
        my ( $rc, $out ) = gen( $d, '0.1.1', '--channel', $channel );
        is( $rc, 0, "$channel: the generator writes" ) or diag($out);
        unlike( $out, qr/compliance:/, "$channel: and does not mention the records" );
        like( slurp("$d/docs/compliance/OBLIGATIONS.md"), qr/^reviewed_at_version: 0\.1\.0$/m, "$channel: they are as they were" );
    }

    # A walk made by hand for the target is not overwritten.
    my $d = repo();
    for my $f (qw(OBLIGATIONS TECHNICAL-FILE)) {
        my $t = slurp("$d/docs/compliance/$f.md");
        $t =~ s/^((?:reviewed_at|covers)_version:\s+)0\.1\.0$/${1}0.1.1/m or die;
        spit( "$d/docs/compliance/$f.md", $t );
    }
    git( $d, 'add', '-A' );
    git( $d, 'commit', '-q', '-m', 'a hand walk' );
    my ( $rc, $out ) = gen( $d, '0.1.1', '--channel', 'stable' );
    is( $rc, 0, 'records already at the target: the generator writes' ) or diag($out);
    unlike( $out, qr/compliance:/, 'and leaves them' );
    unlike( slurp("$d/docs/compliance/OBLIGATIONS.md"), qr/Walked for 0\.1\.1/, 'no second clause on top of a hand walk' );
};

subtest 'a tree with no compliance records is not a refusal' => sub {
    my $d = repo();
    git( $d, 'rm', '-q', '-r', 'docs/compliance' );
    commit( $d, 'no records' );
    my ( $rc, $out ) = gen( $d, '0.1.1', '--channel', 'stable' );
    is( $rc, 0, 'the generator writes' ) or diag($out);
    unlike( $out, qr/compliance:/, 'and does not mention them' );
};

subtest 'the records are release material: the allowlist names them' => sub {
    my $out = run_cmd( $^X, "$root/tools/release-material.pl", '--paths' );
    like( $out, qr{^docs/compliance/OBLIGATIONS\.md$}m,    'OBLIGATIONS.md' );
    like( $out, qr{^docs/compliance/TECHNICAL-FILE\.md$}m, 'TECHNICAL-FILE.md' );
};

done_testing();
