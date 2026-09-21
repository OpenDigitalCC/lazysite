#!/usr/bin/perl
# The practice briefing records when its sources last CHANGED, not when they
# were last touched.
#
# FOUND BY RUNNING THE GATE ON MAIN, which was red. t/lint/89 compares the
# served briefing against a fresh import and failed with the source's sha256
# IDENTICAL in both: the record said `modified=2026-09-09` and a fresh import
# said 2026-09-15 over byte-identical content. The importer took the filesystem
# mtime, and an mtime moves for a checkout, a copy or a branch switch - so a
# generated artefact went stale against a source nobody had edited, and the
# only way to clear it was to regenerate and commit a diff of three metadata
# lines.
#
# A date derived from the content's history is stable across every checkout.
# The mtime stays as the fallback, because a tarball install has no git and an
# approximately right date beats 'unknown'.
#
# DRIVEN AGAINST A REAL REPOSITORY. The whole point is the difference between
# two timestamps, so the fixture commits a file with an old committer date and
# then touches it - which is exactly the state a checkout leaves behind, and
# the state no source-reading test could tell apart.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use POSIX qw(strftime);
use TestHelper qw(repo_root site_tempdir run_cmd);

my $root = repo_root();
my $tool = "$root/tools/import-field-practice.pl";
plan skip_all => "no importer at $tool" unless -f $tool;
plan skip_all => 'git not available'
    unless grep { -x "$_/git" } split /:/, ( $ENV{PATH} // '' );

my $d = site_tempdir();
make_path("$d/practice");

# THE REAL SOURCES, copied. Invented ones do not work and should not: the
# importer refuses to ship when a section it tracks as a field scar has
# vanished from the sources, which is a guard worth keeping and which a
# two-line fixture trips immediately. Only the DATE is under test here, so the
# input may as well be the input.
use File::Copy qw(copy);
for my $f (qw(authoring-practice.md app-practice.md)) {
    copy( "$root/docs/practice/$f", "$d/practice/$f" )
        or BAIL_OUT("copy $f: $!");
}

my $OLD = '2026-03-04';
{
    # THE TWO DATES ARE DELIBERATELY DIFFERENT, and that is the second half of
    # this test. A rebase rewrites the COMMITTER date and leaves the AUTHOR
    # date alone - so an implementation reading %cs goes stale against its own
    # artefact the moment a branch is rebased, which is the mtime fault
    # arriving by another route. Setting both to the same value, as the first
    # draft did, cannot tell the two apart.
    local $ENV{GIT_AUTHOR_DATE}     = "$OLD 12:00:00 +0000";
    local $ENV{GIT_COMMITTER_DATE}  = strftime( '%Y-%m-%d %H:%M:%S +0000', gmtime );
    local $ENV{GIT_AUTHOR_NAME}     = 'Fixture';
    local $ENV{GIT_AUTHOR_EMAIL}    = 'fixture@example.invalid';
    local $ENV{GIT_COMMITTER_NAME}  = 'Fixture';
    local $ENV{GIT_COMMITTER_EMAIL} = 'fixture@example.invalid';
    run_cmd( 'git', '-C', $d, 'init',   '-q' );
    run_cmd( 'git', '-C', $d, 'add',    'practice' );
    run_cmd( 'git', '-C', $d, 'commit', '-q', '-m', 'the practice' );
}

# THE STATE A CHECKOUT LEAVES: content unchanged, mtime now.
my $now = time;
utime $now, $now, "$d/practice/authoring-practice.md", "$d/practice/app-practice.md";

my $out = run_cmd(
    $^X, $tool,
    '--sites'          => "$d/practice/authoring-practice.md",
    '--apps'           => "$d/practice/app-practice.md",
    '--engine-version' => '9.9.9',
    '--stdout',
);
my $rc = $? >> 8;
is( $rc, 0, 'the importer ran' ) or diag($out);

my @dates = ( $out =~ /modified=(\d{4}-\d{2}-\d{2})/g );
cmp_ok( scalar @dates, '>=', 2, 'both sources recorded a date' ) or diag($out);

is_deeply( [ grep { $_ ne $OLD } @dates ], [],
    "every recorded date is the COMMIT date ($OLD), not today's mtime" )
    or diag( "got: @dates\n"
        . 'A date taken from the mtime makes the generated briefing stale '
        . 'against a source nobody edited - which is how t/lint/89 came to '
        . 'fail on main over three metadata lines.' );

# And the fallback still answers, because a tarball has no repository.
subtest 'no repository: the mtime is the fallback, not "unknown"' => sub {
    my $bare = site_tempdir();
    make_path("$bare/practice");
    copy( "$root/docs/practice/$_", "$bare/practice/$_" )
        or BAIL_OUT("copy $_: $!")
        for qw(authoring-practice.md app-practice.md);

    my $o = run_cmd(
        $^X, $tool,
        '--sites'          => "$bare/practice/authoring-practice.md",
        '--apps'           => "$bare/practice/app-practice.md",
        '--engine-version' => '9.9.9',
        '--stdout',
    );
    my @d = ( $o =~ /modified=(\d{4}-\d{2}-\d{2})/g );
    cmp_ok( scalar @d, '>=', 2, 'dates were still recorded' );
    is_deeply( [ grep { !/\A\d{4}-\d{2}-\d{2}\z/ } @d ], [],
        'and each is a real date rather than "unknown"' );
};

done_testing();
