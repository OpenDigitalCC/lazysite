#!/usr/bin/perl
# import-field-practice.pl - build starter/docs/ai-briefing-practice.md from the
# site agent's practice files, which live OUTSIDE this tree (SM574).
#
#   perl tools/import-field-practice.pl                       # write the doc
#   perl tools/import-field-practice.pl --stdout              # print, write nothing
#   perl tools/import-field-practice.pl --engine-version X.Y.Z
#
# WHY THIS EXISTS. The engine serves a briefing set to every connecting agent.
# The site agent keeps a SECOND account - what building and breaking real sites
# and apps actually taught - in two files in its own project trees. One agent
# reads them. Every other agent that connects to a lazysite site starts from the
# engine's briefings alone and relearns the practice one mistake at a time. This
# script pulls those files in so a release carries the practice as it stood.
#
# THE SOURCES ARE PULLED, NOT PUSHED. They are maintained in other projects on
# their own rhythm; nothing there knows this repo exists. So the paths are
# defaults here, the import is re-runnable, and t/lint/88 is what stops the
# served copy drifting from what the agent actually practises.
#
# WHAT THE IMPORT DOES BEYOND COPYING, and why each is not cosmetic:
#
#   - Provenance framing. The served page says whose notes these are, when they
#     were taken, and that the engine's reference docs WIN on conflict. Without
#     that an agent reads one agent's scar tissue as a specification.
#
#   - Version-dated sections keep their before/after columns, and the page
#     states the engine version it was generated for. Resolving those tables
#     down to "current behaviour" would be the tempting simplification and the
#     wrong one: a half-migrated estate is the normal state, and the agent on an
#     0.10.29 site is the one who needs the left-hand column.
#
#   - `datatable` fences become pipe tables. The sources are written for the PDF
#     pipeline, where ```datatable IS a table. Served through the engine that
#     fence renders as a CODE BLOCK - so shipping the text unchanged would lose
#     the before/after columns in the very act of shipping them.
#
#   - The author-facing section ("Keeping this current" - instructions to the
#     person maintaining the source) is dropped and replaced by one line saying
#     where updates come from. It is meaningless on a served page.
#
# The body checksum written into the provenance block is what lets the gate
# catch an edit to the served copy on a machine where the sources do not exist,
# which is every machine except the one the site agent works on.
use strict;
use warnings;
use Cwd            qw(abs_path);
use Digest::SHA    qw(sha256_hex);
use File::Basename qw(dirname);
use Getopt::Long   qw(GetOptions);
use POSIX          qw(strftime);

my $ROOT = dirname( dirname( abs_path($0) ) );

# The canonical sources. Defaults, not constants: an operator re-importing from
# a checkout elsewhere passes --sites/--apps rather than editing this file.
# SM733: THE SOURCES LIVE IN THIS REPO NOW.
#
# They were read from the site agent's own trees, which made the shipped
# briefing depend on two paths outside the repository - SM597 filed that as
# coupling every gate to a file it does not own, and it is also how the
# 2026-09-02 client names reached the import boundary before anyone with
# custody of the shipped artefact could see them.
#
# The site agent still MAINTAINS them; the release side is custodian of what
# ships. That split is the point: whoever answers for the published document
# holds the copy that gets published.
my $SITES_SRC = "$ROOT/docs/practice/authoring-practice.md";
my $APPS_SRC  = "$ROOT/docs/practice/app-practice.md";
my $OUT       = "$ROOT/starter/docs/ai-briefing-practice.md";

# Sections that are instructions to the AUTHOR of the source, not practice. They
# are dropped and answered by one line in the provenance section instead.
my %DROP = ( 'Keeping this current' => 1 );

# Sections that hold WHATEVER engine a site runs - the field scars. Listed by
# title rather than inferred, because the framing they get is a promise the page
# makes and a guess must not be able to make it. A title that stops matching is
# a hard error, not a silent downgrade to unmarked: the notes were renamed and
# somebody has to look.
my %FIELD_SCAR = (
    'Things that look equivalent and are not' => 1,
    'Verify like this'                        => 1,
);

# A section is version-dated when it names an engine version. Detected rather
# than listed, so a new before/after section added upstream is marked without
# anyone remembering to come here. %FIELD_SCAR wins where both would fire: those
# sections cite versions as EVIDENCE ("shipped in 0.10.30 with no capability
# declared") while the lesson itself is timeless.
my $VERSION_MENTION = qr/\b\d+\.\d+\.\d+\b/;

my $engine_version = '';
my $agent          = 'the lazysite site agent (Claude Code)';
my $import_date    = strftime( '%Y-%m-%d', localtime );
my $to_stdout      = 0;

GetOptions(
    'sites=s'          => \$SITES_SRC,
    'apps=s'           => \$APPS_SRC,
    'out=s'            => \$OUT,
    'engine-version=s' => \$engine_version,
    'agent=s'          => \$agent,
    'date=s'           => \$import_date,
    'stdout'           => \$to_stdout,
    ) or die "usage: import-field-practice.pl [--sites P] [--apps P] [--out P]"
    . " [--engine-version X.Y.Z] [--agent NAME] [--date YYYY-MM-DD] [--stdout]\n";

$engine_version ||= default_engine_version();

my $doc = build_doc();

# SM731: REFUSE TO PUBLISH A CLIENT'S NAME.
#
# This document ships to EVERY lazysite installation. Its sources are field
# notes written by an agent working on real client sites, so the natural way to
# make a point is to name the site it was learned on - and the 2026-09-02 import
# carried two: a named client site with a comparative judgement about the
# quality of its markup, and a client project named as the origin of a ruling.
#
# The guard is here rather than in the source trees because those belong to
# another agent, and because a rule enforced at the boundary cannot be forgotten
# by whoever writes the next note. The lesson always survives redaction: "one
# site does X, another does Y" carries the same weight as naming them.
{
    my @IDENT = qw(
        familyhq jpm jpmorris marriage-morris thisisus outsourcify cloudient
        dhcf dito odysseytimeship theunited harmony2050 mackintosh mm-gallery
        kestrel oldbarn old-barn sovereign hygge ispadmin nextcloud
    );
    my ( @found, $ln );
    for my $line ( split /\n/, $doc ) {
        $ln++;
        for my $id (@IDENT) {
            push @found, "  line $ln: $id  ->  " . substr( $line, 0, 88 )
                if $line =~ /\b\Q$id\E\b/i;
        }
    }
    if (@found) {
        die "import-field-practice.pl: REFUSING to write $OUT - the practice "
            . "sources name a client, and this document ships to every site.\n"
            . join( "\n", @found ) . "\n\n"
            . "Redact in the SOURCE (the notes belong to the site agent - file "
            . "to its inbox), then re-run. The point being made almost always "
            . "survives: name the shape, not the site.\n";
    }
}


if ($to_stdout) { print $doc }
else {
    open my $fh, '>', $OUT or die "import-field-practice.pl: $OUT: $!\n";
    print {$fh} $doc;
    close $fh or die "import-field-practice.pl: $OUT: $!\n";
    print "wrote $OUT (" . length($doc) . " bytes, engine $engine_version)\n";
}
exit 0;

# --- inputs ---

# THE VERSION STAMP IS THE RELEASE BEING CUT, not the one before it. VERSION is
# stamped in the release stage from the version being built (SM375), so at build
# time VERSION is right. On the development branch it still names the LAST
# release, and the doc is being prepared for the next one - so NEXT_VERSION is
# the honest answer there. t/lint/88 accepts either and nothing else, which is
# what stops a hand-typed version reaching the page.
sub default_engine_version {
    my $stage = read_file_or_undef("$ROOT/VERSION");
    my $next  = read_file_or_undef("$ROOT/NEXT_VERSION");
    for my $v ( $next, $stage ) {
        next unless defined $v;
        $v =~ s/\s+//g;
        return $v if $v =~ /\A\d+\.\d+\.\d+\z/;
    }
    die "import-field-practice.pl: no usable VERSION/NEXT_VERSION;"
        . " pass --engine-version\n";
}

sub read_file_or_undef {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

sub slurp {
    my ($path) = @_;
    my $text = read_file_or_undef($path);
    die "import-field-practice.pl: cannot read source $path: $!\n"
        unless defined $text;
    return $text;
}

sub file_date {
    my ($path) = @_;
    my @st = stat $path or return 'unknown';
    return strftime( '%Y-%m-%d', localtime( $st[9] ) );
}

# --- section handling ---

# Split a source into its H2 sections, IGNORING fenced regions. A `## ` inside a
# code fence is example text, and a splitter that cannot tell the difference
# invents a section out of somebody's shell transcript.
sub split_sections {
    my ($text) = @_;
    my @lines  = split /\n/, $text, -1;
    my ( @sections, $current );
    my $in_fence = 0;
    for my $line (@lines) {
        $in_fence = !$in_fence if $line =~ /\A```/;
        if ( !$in_fence && $line =~ /\A##\s+(.+?)\s*\z/ ) {
            push @sections, $current if $current;
            $current = { title => $1, body => [] };
            next;
        }
        push @{ $current->{body} }, $line if $current;
    }
    push @sections, $current if $current;
    return @sections;
}

sub classify {
    my ($section) = @_;
    return 'field-scar' if $FIELD_SCAR{ $section->{title} };
    my $whole = $section->{title} . "\n" . join( "\n", @{ $section->{body} } );
    return 'version-dated' if $whole =~ $VERSION_MENTION;
    return 'general';
}

# A ```datatable fence is a PDF-pipeline table. Rewrite it as a pipe table,
# which Text::MultiMarkdown renders as a real table - the columns are the
# content here, not decoration.
sub datatable_to_pipe_table {
    my ( $lines_ref, $where ) = @_;
    my @out;
    my $i = 0;
    while ( $i <= $#$lines_ref ) {
        my $line = $lines_ref->[$i];
        if ( $line !~ /\A```datatable\s*\z/ ) {
            push @out, $line;
            $i++;
            next;
        }

        # Header keys (columns:/widths:/bold:/tone:/text:), then `---`, then rows.
        my ( @header, @rows, $seen_rule, $closed );
        $i++;
        while ( $i <= $#$lines_ref ) {
            my $l = $lines_ref->[$i];
            $i++;
            if   ( $l =~ /\A```\s*\z/ )                { $closed = 1; last }
            if   ( !$seen_rule && $l =~ /\A---\s*\z/ ) { $seen_rule = 1; next }
            if   ($seen_rule)                          { push @rows, $l }
            else                                       { push @header, $l }
        }
        die "import-field-practice.pl: unterminated datatable in $where\n"
            unless $closed;

        my ($cols_line) = grep { /\Acolumns:/ } @header;
        die "import-field-practice.pl: datatable with no columns: in $where\n"
            unless defined $cols_line;
        $cols_line =~ s/\Acolumns:\s*//;
        my @cols = map { trim($_) } split /\s*\|\s*/, $cols_line;

        push @out, '' if @out && length $out[-1];
        push @out, '| ' . join( ' | ', @cols ) . ' |';
        push @out, '|' . ( ' --- |' x scalar @cols );
        for my $row (@rows) {
            next unless length trim($row);
            my @cells = map { trim($_) } split /\s*\|\s*/, $row, -1;
            die "import-field-practice.pl: datatable row in $where has "
                . scalar(@cells)
                . " cells for "
                . scalar(@cols)
                . " columns: $row\n"
                if @cells > @cols;
            push @cells, '' while @cells < @cols;
            push @out,   '| ' . join( ' | ', @cells ) . ' |';
        }
        push @out, '';
    }
    return @out;
}

sub trim {
    my ($s) = @_;
    $s //= '';
    $s =~ s/\A\s+//;
    $s =~ s/\s+\z//;
    return $s;
}

# --- assembly ---

sub render_section {
    my ( $section, $where ) = @_;
    my $kind = classify($section);
    my @body = datatable_to_pipe_table( $section->{body}, $where );

    # Trim leading/trailing blank lines so the marker line sits against the
    # heading and the sections space evenly however the source was spaced.
    shift @body while @body && !length trim( $body[0] );
    pop @body   while @body && !length trim( $body[-1] );

    my @out = ("## $section->{title}");
    push @out, '';
    if ( $kind eq 'version-dated' ) {

        # Only claim the columns where there are columns. Several version-dated
        # sections are prose, and a marker that describes a table the reader
        # cannot see reads as a page describing some other page.
        my $has_table = grep { /\A\|\s*---/ } @body;
        my $columns
            = $has_table
            ? ' The before/after columns below are kept on purpose.'
            : '';
        # SM620: the note says the behaviour is version-DEPENDENT and tells the
        # reader to check the engine. It used to append "Imported for engine
        # X.Y.Z" as well, which is the ONE version this document already states
        # at the top - repeated here, and in every other note, so a re-import
        # rewrote a dozen lines to say the same new number. The header stamp is
        # the single reference; this points at it rather than copying it.
        push @out,
            '*Version-dated - this describes behaviour that **differs by engine'
            . " version**.$columns Check which engine the site runs before"
            . ' acting on it, and compare it with the version this copy was'
            . ' generated for, at the top.*';
        push @out, '';
    }
    elsif ( $kind eq 'field-scar' ) {

        # SM620: this one was WRONG, not merely repetitive. It read "it held
        # before engine X and holds after it" - a sentence whose entire claim is
        # that the version does not matter, anchored to whichever version was
        # last cut. Re-importing moved it, so on 0.11.5 a reader was told a
        # version-independent scar held before 0.11.5: true, uninformative, and
        # quietly narrower than the author meant. It names no version now,
        # because that is what version-independent means.
        push @out,
            '*Version-independent - a field scar. It holds on any site you'
            . ' connect to, whatever engine that site runs.*';
        push @out, '';
    }
    push @out, @body;
    push @out, '';
    return @out;
}

sub build_doc {
    my $sites_text = slurp($SITES_SRC);
    my $apps_text  = slurp($APPS_SRC);

    my %source = (
        sites => {
            path     => $SITES_SRC,
            sha256   => sha256_hex($sites_text),
            modified => file_date($SITES_SRC),
        },
        apps => {
            path     => $APPS_SRC,
            sha256   => sha256_hex($apps_text),
            modified => file_date($APPS_SRC),
        },
    );

    my %seen;
    my @body;
    push @body, framing();

    push @body, part(
        'Part one: sites and content',
        'Pages, layout, theme, HTML and styling.',
        $sites_text, $source{sites}{path}, \%seen,
    );
    push @body, part(
        'Part two: apps and data',
        'Workflow, where state lives, how data is stored and read back, and'
            . ' who is allowed to see it.',
        $apps_text, $source{apps}{path}, \%seen,
    );

    # A promised framing that can no longer be delivered is a hard failure. If a
    # field-scar section is renamed upstream this import would quietly ship it
    # unmarked - the one outcome worth stopping a build for, because the marking
    # is the reason those sections carry their weight. A DROPPED section going
    # missing is only a note: the author is entitled to delete their own
    # instructions to themselves.
    for my $title ( sort keys %FIELD_SCAR ) {
        die "import-field-practice.pl: field-scar section '$title' is not in the"
            . " sources any more - it was renamed or removed, and shipping it"
            . " unmarked would be worse than not shipping it. Fix %FIELD_SCAR.\n"
            unless $seen{$title};
    }
    for my $title ( sort keys %DROP ) {
        warn "import-field-practice.pl: note: '$title' was not in the sources,"
            . " so there was nothing to drop\n"
            unless $seen{$title};
    }

    push @body, provenance_section( \%source );

    # Normalise to at most one blank line between blocks, then checksum the
    # rendered body. The checksum covers exactly what a reader sees and nothing
    # that describes it, so the provenance block is not inside its own digest.
    #
    # ORDER MATTERS. The front matter has to be the first bytes of the file -
    # the processor's parser anchors on \A--- - so the provenance comment goes
    # between the front matter and the body, not above it.
    my $text = join( "\n", @body );
    $text =~ s/\n{3,}/\n\n/g;
    $text =~ s/\A\s*/\n/;       # exactly one blank line below the comment
    $text =~ s/\s*\z/\n/;

    return join( '',
        join( "\n", front_matter() ),
        provenance_comment( \%source, $text ), $text );
}

sub front_matter {
    return (
        '---',
        'title: AI briefing - field practice',
        'subtitle: One agent\'s field notes from building and breaking real sites'
            . ' and apps on this engine - a companion to the reference briefings,'
            . ' not a specification.',
        'register:',
        '  - sitemap.xml',
        '---',
        '',
    );
}

# The machine-readable half of the provenance. Kept as an HTML comment so the
# gate has something exact to read without putting checksums in front of a
# reader who wants the practice; the prose half is provenance_section().
sub provenance_comment {
    my ( $source, $body ) = @_;
    return join( "\n",
        '<!-- lazysite:field-practice-import',
        "     generator: tools/import-field-practice.pl",
        "     engine-version: $engine_version",
        "     imported: $import_date",
        "     agent: $agent",
        "     source: $source->{sites}{path}"
            . " sha256=$source->{sites}{sha256} modified=$source->{sites}{modified}",
        "     source: $source->{apps}{path}"
            . " sha256=$source->{apps}{sha256} modified=$source->{apps}{modified}",
        '     body-sha256: ' . sha256_hex($body),
        '-->',
        '' );
}

sub framing {
    return (
        '## What this is, and what it is not',
        '',
        'These are **one agent\'s field notes** from building and breaking real'
            . ' sites and apps on this engine. They are a **companion to the'
            . ' engine\'s reference briefings, not a specification**: nothing here'
            . ' defines behaviour, and nothing here was written by the engine.',
        '',
        '**Where these notes conflict with the engine\'s reference docs, the'
            . ' reference docs win, and the conflict is a bug in these notes.**'
            . ' Report it rather than working around it - a stale line here is'
            . ' worse than no line, because it will be trusted.',
        '',
        "This copy was **generated for engine $engine_version**. The last"
            . ' section, *Where this came from*, names the sources, the agent and'
            . ' the dates.',
        '',
        '## How the sections are marked',
        '',
        'Some of what the field learns is true of one engine version and false of'
            . ' the next, and some of it is true whatever engine a site runs. They'
            . ' are worth different amounts to you, so they are marked:',
        '',
        '| Marking | What it means |',
        '| --- | --- |',
        '| **Version-dated** | Behaviour that **differs by engine version**, kept'
            . ' as before/after columns. Not resolved down to "current behaviour":'
            . ' a half-migrated estate is the normal state, and the agent on an'
            . ' older site is the one who needs the left-hand column. Check the'
            . ' engine a site runs before acting on one of these. |',
        '| **Version-independent** | A field scar. It cost somebody real time,'
            . ' it does not depend on a version, and it is the most useful part of'
            . ' this page. |',
        '| unmarked | General practice - judgement and habit rather than'
            . ' mechanism. |',
        '',
        'The engine version a **running** site reports is not necessarily this'
            . ' one. The briefing set is served from the site\'s own docroot, so a'
            . ' site installed from an older release serves an older copy of this'
            . ' page.',
        '',
    );
}

# Every heading stays at H2, including the part dividers. No shipped
# documentation page puts an H1 in its body - the layout renders the front
# matter title as the page's only H1 - and a body H1 arriving after the H2s
# above it would invert the outline for anything reading the page structurally.
sub part {
    my ( $title, $blurb, $text, $path, $seen ) = @_;
    my @out = ( "## $title", '', "*$blurb*", '' );

    my @sections = split_sections($text);
    die "import-field-practice.pl: no H2 sections found in $path\n"
        unless @sections;

    for my $section (@sections) {
        $seen->{ $section->{title} } = 1;
        next if $DROP{ $section->{title} };
        push @out, render_section( $section, $path );
    }

    return @out;
}

sub provenance_section {
    my ($source) = @_;
    return (
        '## Where this came from',
        '',
        # SM620: the engine version is stated ONCE, at the top, where a reader
        # meets it before acting on anything here. This section is about WHERE
        # the material came from - date, author, sources - so it says that and
        # points at the stamp rather than carrying a second copy that a
        # re-import has to keep in step.
        "Imported on **$import_date** by `tools/import-field-practice.pl`, for the"
            . ' engine version stamped at the top of this page. Written by'
            . " **$agent** - the agent that builds and maintains sites on this"
            . ' engine - as a working record, and kept current in its own'
            . ' project trees:',
        '',
        '| Source | Covers | Last changed |',
        '| --- | --- | --- |',
        "| `$source->{sites}{path}` | sites and content"
            . " | $source->{sites}{modified} |",
        "| `$source->{apps}{path}` | apps and data"
            . " | $source->{apps}{modified} |",
        '',
        'Those paths are on the site agent\'s own machine and are **not** part of'
            . ' this engine. **Updates come from re-running the import**, which'
            . ' happens when a release is cut; a sysop can also run it between'
            . ' releases. Nothing you edit on this page survives the next import,'
            . ' and the engine\'s own test suite fails the build if this copy stops'
            . ' matching its sources - so a correction belongs in the source files,'
            . ' not here.',
        '',
        'If you have found something durable that is missing - a mechanism worth'
            . ' reaching for, a trap worth naming, a measurement worth keeping -'
            . ' send it to the sysop for the source files rather than adding it'
            . ' to the site.',
        '',
    );
}
