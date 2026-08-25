#!/usr/bin/perl
# SM574: the served field-practice briefing matches what it was imported from.
#
# starter/docs/ai-briefing-practice.md is GENERATED, by
# tools/import-field-practice.pl, from two files that live outside this repo -
# the site agent's AUTHORING-PRACTICE.md and APP-PRACTICE.md. It ships in every
# release and every connecting agent reads it. So it has two ways to become a
# lie, and this gate closes both:
#
#   1. SOMEBODY EDITS THE SERVED COPY. Tempting, and invisible: the page reads
#      as prose and nothing about it says "do not edit". The next import silently
#      reverts the edit, so the correction is lost AND the page disagrees with
#      what the agent actually practises in between.
#
#   2. THE SOURCES MOVE ON. The practice is a living record and changes on its
#      own rhythm; a release that carries a six-month-old copy is serving advice
#      the author has already corrected.
#
# TWO CHECKS, BECAUSE THE SOURCES ARE NOT ALWAYS THERE. The canonical paths exist
# on one machine. Everywhere else - a release tarball, CI, a fresh clone - they
# do not, and a gate that could only run there would be a gate that never runs.
# So the page carries a body-sha256 of its own rendered body, which catches an
# edit to the served copy with no sources present at all; and where the sources
# ARE readable, the import is re-run and compared byte for byte, which catches
# both failures at once.
#
# The rest asserts what SM574 required the page to SAY, because those are
# promises to a reader rather than properties of a file: the provenance framing
# (one agent's notes, not a specification; the reference docs win on conflict),
# the engine version it was generated for, the before/after columns kept on the
# version-dated sections, the field-scar sections marked version-independent,
# and the author-facing section gone.
use strict;
use warnings;
use Test::More;
use Digest::SHA qw(sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $doc  = "$root/starter/docs/ai-briefing-practice.md";
my $gen  = "$root/tools/import-field-practice.pl";

ok( -f $doc, 'the field-practice briefing is present' )
    or do { done_testing; exit };
ok( -f $gen, 'its import script is present' ) or do { done_testing; exit };

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

sub read_version_file {
    my ($name) = @_;
    my $p = "$root/$name";
    return unless -f $p;
    my $v = slurp($p);
    $v =~ s/\s+//g;
    return $v;
}

my $text = slurp($doc);

# --- the machine-readable provenance block ---

my ($prov) = $text =~ /<!--\s*lazysite:field-practice-import\n(.*?)\n-->/s;
ok( $prov, 'the page carries its machine-readable provenance block' )
    or do { done_testing; exit };

my ($stamped_version) = $prov =~ /^\s*engine-version:\s*(\S+)\s*$/m;
my ($body_sha)        = $prov =~ /^\s*body-sha256:\s*([0-9a-f]{64})\s*$/m;
my ($imported)        = $prov =~ /^\s*imported:\s*(\d{4}-\d\d-\d\d)\s*$/m;
my ($agent)           = $prov =~ /^\s*agent:\s*(\S.*?)\s*$/m;
my @sources           = $prov =~ /^\s*source:\s*(\S+)\s+sha256=([0-9a-f]{64})/mg;

ok( defined $imported, 'it records the date it was imported' );
ok( defined $agent && length $agent,
    'it names the agent whose field notes these are' );
is( scalar(@sources) / 2, 2, 'it records both import sources with a checksum' );
ok( defined $body_sha, 'it records a checksum of its own body' );

# THE VERSION STAMP IS EITHER THE LAST RELEASE OR THE ONE BEING CUT, and nothing
# else. Free text here would let a hand-typed version reach the page, which is
# the one field a reader on an old site acts on directly.
subtest 'it states the engine version it was generated for' => sub {
    ok( defined $stamped_version, 'a version is stamped' ) or return;
    like( $stamped_version, qr/\A\d+\.\d+\.\d+\z/, 'and it is a semver' );

    my @allowed = grep { defined } read_version_file('VERSION'),
        read_version_file('NEXT_VERSION');
    plan skip_all => 'no VERSION/NEXT_VERSION to compare against'
        unless @allowed;
    ok( ( grep { $_ eq $stamped_version } @allowed ),
        "$stamped_version is the released engine or the one being cut (@allowed)" )
        or diag(
        'Re-run tools/import-field-practice.pl - the doc was generated for an '
            . 'engine this tree is no longer building.' );
};

my $shown_version = $stamped_version // '';
like( $text, qr/\*\*generated for engine \Q$shown_version\E\*\*/,
    'and says so where a reader will see it, not only in the comment' );

# --- the body checksum: an edit to the served copy, with no sources needed ---

my ($body) = $text =~ /<!--\s*lazysite:field-practice-import.*?-->\n(.*)\z/s;
ok( defined $body, 'the body after the provenance block is readable' );

is( sha256_hex( $body // '' ),
    $body_sha,
    'the served body matches the checksum the import recorded for it' )
    or diag( join "\n  ",
    '',
    'This page is GENERATED. Something has edited the served copy directly.',
    'The next import will revert it, so the change is lost either way - and',
    'until then the engine is serving advice its author did not write.',
    '',
    'A correction belongs in the source file, followed by:',
    '  perl tools/import-field-practice.pl' );

# --- the sources, where they exist: regenerate and compare ---

my @source_paths = @sources[ grep { $_ % 2 == 0 } 0 .. $#sources ];
my @source_sums  = @sources[ grep { $_ % 2 == 1 } 0 .. $#sources ];

my @missing = grep { !-r $_ } @source_paths;

if (@missing) {

    # Not a failure. The sources are one agent's working files on one machine;
    # a release tarball, CI and a fresh clone will never see them, and the body
    # checksum above has already answered the question that matters there.
    note( 'import sources not readable here, so the regeneration check is '
            . 'skipped: ' . join( ', ', @missing ) );
}
else {
    for my $i ( 0 .. $#source_paths ) {
        is( sha256_hex( slurp( $source_paths[$i] ) ),
            $source_sums[$i],
            "$source_paths[$i] is unchanged since the import" )
            or diag( 'The practice has moved on. Re-run '
                . 'tools/import-field-practice.pl so the release does not ship a '
                . 'copy its author has already corrected.' );
    }

    my $cmd = join( ' ',
        $^X,                quotemeta($gen), '--stdout',
        '--engine-version', quotemeta($stamped_version),
        '--agent',          quotemeta($agent),
        '--date',           quotemeta($imported),
        '--sites',          quotemeta( $source_paths[0] ),
        '--apps',           quotemeta( $source_paths[1] ),
        '2>&1' );
    my $regenerated = qx($cmd);
    my $rc          = $? >> 8;
    is( $rc, 0, 'the import re-runs against the sources' ) or diag($regenerated);

    is( $regenerated, $text,
        'the served copy is exactly what importing the sources produces now' )
        or diag( join "\n  ",
        '',
        'The served copy and its sources have diverged. Either the practice',
        'moved on and the release would ship a stale copy, or the page was',
        'edited here. Both are answered the same way:',
        '',
        '  perl tools/import-field-practice.pl' );
}

# --- what SM574 required the page to say ---

subtest 'the provenance framing is on the page, not just the paths' => sub {

    # Phrased as SM574 phrased it. These are what stop an agent reading one
    # agent's scar tissue as a specification, so they are asserted as claims
    # rather than left to whoever next edits the generator.
    like( $text, qr/one agent's field notes/i,
        'it says these are one agent\'s field notes' );
    like( $text, qr/building and breaking real sites/i,
        'from building and breaking real sites' );
    like( $text, qr/not a specification/i, 'and are not a specification' );
    like(
        $text,
        qr/reference docs win.{0,80}bug in these notes/is,
        'and that on a conflict the reference docs win and the notes carry the bug'
    );
    like( $text, qr/\Q$agent\E/,           'it names the agent' );
    like( $text, qr/\Q$imported\E/,        'and the date' );
    like( $text, qr/\Q$source_paths[0]\E/, 'and its first source path' );
    like( $text, qr/\Q$source_paths[1]\E/, 'and its second' );
};

subtest 'version-dated sections keep their before/after columns' => sub {
    my @marked = $text =~ /^\*Version-dated[^\n]*$/mg;
    cmp_ok( scalar @marked, '>=', 3,
        'the version-dated sections are marked as such' );

    # The sources write these as ```datatable, which is a table in the PDF
    # pipeline and a CODE BLOCK when the engine serves it. Losing the columns in
    # the act of shipping them is the specific failure this asserts against.
    unlike( $text, qr/^```datatable/m,
        'no datatable fence survived the import - it would render as a code block'
    );

    my $before_after = 0;
    for my $section ( split /^## /m, $text ) {
        next unless $section =~ /^\*Version-dated/m;
        $before_after++ if $section =~ /^\|\s*---/m;
    }
    cmp_ok( $before_after, '>=', 3,
        'and the ones that had columns still have them, as rendered tables' );

    like( $text, qr/half-migrated|older site|which engine the site runs/i,
        'the page says why the old columns are kept' );
};

subtest 'field-scar sections ship, framed as version-independent' => sub {
    for my $title ( 'Things that look equivalent and are not', 'Verify like this' )
    {
        my ($section) = $text =~ /^## \Q$title\E\n(.*?)(?=^## |\z)/ms;
        ok( $section, "'$title' is on the page" ) or next;
        like( $section, qr/^\*Version-independent/m,
            "'$title' is framed as version-independent" );
    }
};

# SM574: instructions to the author of the source. On a served page they address
# a reader who cannot act on them and point at files they cannot reach.
subtest 'the author-facing section is gone, and answered' => sub {
    unlike( $text, qr/^## Keeping this current/m,
        'the "Keeping this current" section is not served' );
    like( $text, qr/Updates come from re-running the import/i,
        'and the page says where updates come from instead' );
};

# The briefing set is discovered by slug (lib/Lazysite/Capabilities.pm scans for
# ai-briefing-*), so this file's NAME is what puts it in front of an agent, and
# its front matter is what describes it there.
subtest 'it is discoverable as a briefing' => sub {
    like( $doc, qr{/starter/docs/ai-briefing-[a-z-]+\.md\z},
        'it is named as a briefing, which is how describe_capabilities finds it' );
    like( $text, qr/\A---\ntitle:\s*\S/,
        'front matter is the first bytes of the file, with a title' );
    like( $text, qr/^subtitle:\s*\S/m, 'and a subtitle for the index entry' );
    my ($fm) = $text =~ /\A---\n(.*?)\n---\n/s;
    ok( $fm, 'the front matter parses' ) or return;
    like( $fm, qr/^register:\n\s+- sitemap\.xml$/m,
        'and it registers for the sitemap, like its siblings' );

    # t/lint/46: shipped documentation stays out of llms.txt, where it would
    # crowd out the site's own account of itself. Asserted against the front
    # matter alone - the imported practice discusses llms.txt as a subject.
    unlike( $fm, qr/llms\.txt/, 'and not for llms.txt' );
};

done_testing();
