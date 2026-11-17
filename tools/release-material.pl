#!/usr/bin/perl
# tools/release-material.pl - write every mechanical piece of a release into a
# checkout: the one generator the gate and the build both run (SM971).
#
#   perl tools/release-material.pl VERSION --dir DIR [--channel C]
#                                  [--notes FILE] [--date YYYY-MM-DD]
#   perl tools/release-material.pl --paths               # the allowlist
#   perl tools/release-material.pl --lints --dir DIR     # the checks on it
#   perl tools/release-material.pl --notes FILE --print annotation|trailers|subtitle
#
# WHAT IT WRITES, in DIR (a clean checkout - the gate's stage or the build's):
#
#   CHANGELOG.md   `## Unreleased` becomes `## X.Y.Z - CHANNEL: subtitle (DATE)`
#                  under a fresh empty `## Unreleased`, and the ref of every
#                  entry still marked PENDING is replaced by its landed SHA.
#   CHANGELOG-archive.md
#                  at a new minor (X.Y.0), the earlier minors' sections move
#                  there unchanged (lint 210, SM946).
#   docs/FEATURES.md
#                  the timeline entry, and the subtitle's "as of vX.Y.Z".
#   VERSION, NEXT_VERSION
#                  X.Y.Z and X.Y.(Z+1), by tools/bump-version.pl.
#   starter/lazysite/templates/docs/ai-briefing-practice.md
#                  re-imported for X.Y.Z (tools/import-field-practice.pl).
#   docs/INDEX.md  regenerated (tools/gen-doc-index.pl --write).
#   docs/feature-requests/*.md
#                  the status-note of every filing whose id has an entry in the
#                  released section and still says "SHIPPED (PENDING)" says
#                  "SHIPPED (X.Y.Z)" (P22). A filing whose bullet is stamped with
#                  its landed SHA here and whose status is `candidate` becomes
#                  `shipped` - `partial` when the bullet names a part, `SM1454
#                  (R3)` - its note opened "SHIPPED (X.Y.Z): " (SM1454 R6 b).
#   docs/compliance/OBLIGATIONS.md, docs/compliance/TECHNICAL-FILE.md
#                  a PATCH (X.Y.Z, Z > 0) of a release whose records were
#                  walked at that release, on the stable, edge or beta channel:
#                  reviewed_at_version, reviewed_on and covers_version say the
#                  target, and a dated patch-walk clause names the diff's runtime
#                  files and register entries (SM1454 R6 a, R7). See compliance().
#                  A minor and a certified cut leave them to the hand walk.
#
# THE GATE RUNS IT TOO, without notes: the subtitle and the FEATURES prose are
# placeholders, everything else is what the build will write. So the gate tests
# the tree that ships, and main can pass a gate at any moment - there is no
# pre-cut pass to wait for, and no rehearsal.
#
# A PENDING REF IS RESOLVED FROM GIT, NEVER GUESSED. For each entry whose first
# line carries `(PENDING)` in its ref position, the commit is the one, since the
# newest tag reachable from HEAD, whose diff ADDED that exact line to
# CHANGELOG.md (`git log -S`, then each candidate's own diff). Zero such
# commits, more than one, or the same line twice in the file: the entry is named
# and nothing is written. A wrong SHA in a released section is the defect
# SM354 was filed for; a refusal costs one hand edit.
#
# THE NOTES FILE starts with a header block, ended by its first blank line:
#
#   Subtitle: an install says whether the site works
#   Features: Provision ends by running the health check and exits non-zero
#     when the site is not serviceable (SM933). Continuation lines are indented.
#   Assisted-by: Claude:claude-opus-5-5[1m]
#   Claude-Session: https://claude.ai/code/session_...
#
# Subtitle and Features are required; Assisted-by and Claude-Session are the
# release commit's trailers (release.sh build requires Assisted-by). Everything
# after the blank line is the tag annotation.
#
# Exit: 0 written, 1 refused (the reason on stderr; DIR is left as the step that
# refused found it, which in a stage is thrown away), 2 usage.
use strict;
use warnings;
use Cwd            qw(abs_path getcwd);
use File::Basename qw(dirname);
use Getopt::Long   qw(GetOptions);
use POSIX          qw(strftime);
use Text::Wrap     qw(wrap);

# THE RELEASE-MATERIAL ALLOWLIST. A release commit touches these and nothing
# else: release.sh build refuses a commit whose diff names any other path, and a
# main that moved past its gate only through these needs no new gate.
# GATE-LOG.md and coverage-last.json are written by release.sh itself (the row,
# the coverage record); the two compliance records are stamped by compliance()
# when the cut is a patch (SM1454 R6 a, R7).
my @ALLOWLIST = qw(
    CHANGELOG.md
    docs/releases/CHANGELOG-archive.md
    docs/FEATURES.md
    docs/INDEX.md
    starter/lazysite/templates/docs/ai-briefing-practice.md
    VERSION
    NEXT_VERSION
    docs/releases/GATE-LOG.md
    dist/config/coverage-last.json
    docs/feature-requests/
    docs/compliance/OBLIGATIONS.md
    docs/compliance/TECHNICAL-FILE.md
);

# THE CHECKS THAT READ THOSE FILES - every lint naming one of them (t/lint/214
# keeps this list complete), and the briefing's own unit test. release.sh build
# runs them on the release commit; together they take well under a minute.
my @LINTS = qw(
    t/lint/03- t/lint/08- t/lint/09- t/lint/26- t/lint/27- t/lint/36- t/lint/53-
    t/lint/62- t/lint/63- t/lint/65- t/lint/75- t/lint/89- t/lint/110-
    t/lint/113- t/lint/138- t/lint/145- t/lint/149- t/lint/199- t/lint/207- t/lint/210- t/lint/244-
    t/lint/270- t/lint/274- t/lint/292-
    t/lint/307-
    t/lint/310- t/lint/311-
    t/lint/320-
    t/unit/tools/71-
);

my $PLACEHOLDER_SUBTITLE = 'gated before its notes were written';
my $PLACEHOLDER_FEATURES =
    'Written by the gate; the build writes this entry from the release notes.';

my %opt = ( channel => 'edge' );
GetOptions(
    'dir=s'     => \$opt{dir},
    'channel=s' => \$opt{channel},
    'notes=s'   => \$opt{notes},
    'date=s'    => \$opt{date},
    'paths'     => \$opt{paths},
    'lints'     => \$opt{lints},
    'print=s'   => \$opt{print},
) or usage();

if ( $opt{paths} ) { print "$_\n" for @ALLOWLIST;      exit 0 }
if ( $opt{lints} ) { print "$_\n" for resolve_lints(); exit 0 }
if ( defined $opt{print} ) {
    defined $opt{notes} or usage('--print needs --notes FILE');
    my $n = read_notes( $opt{notes} );
    if    ( $opt{print} eq 'annotation' ) { print $n->{annotation} }
    elsif ( $opt{print} eq 'trailers' )   { print "$_\n" for @{ $n->{trailers} } }
    elsif ( $opt{print} eq 'subtitle' )   { print "$n->{subtitle}\n" }
    else { usage('--print annotation|trailers|subtitle') }
    exit 0;
}

my $VERSION = shift @ARGV;
usage('VERSION is X.Y.Z') unless defined $VERSION && $VERSION =~ /\A(\d+)\.(\d+)\.(\d+)\z/;
my ( $MAJ, $MIN, $PAT ) = ( $1, $2, $3 );
usage('--dir DIR is required') unless defined $opt{dir};
usage('extra argument') if @ARGV;
my %CHANNELS = map { $_ => 1 } qw(edge beta stable certified);
usage("--channel is one of: @{[ sort keys %CHANNELS ]}") unless $CHANNELS{ $opt{channel} };
my $DATE = $opt{date} // strftime( '%Y-%m-%d', localtime );
usage('--date is YYYY-MM-DD') unless $DATE =~ /\A\d{4}-\d{2}-\d{2}\z/;

my $DIR = abs_path( $opt{dir} ) // refuse("--dir $opt{dir} does not exist");
refuse("$DIR is not the top of a git checkout")
    unless ( git_out( 'rev-parse', '--show-toplevel' ) // '' ) eq $DIR;
my $dirty = git_out( 'status', '--porcelain' );
refuse( "$DIR has uncommitted changes; the generator writes into a clean checkout so "
        . "that its diff is its own:\n$dirty" )
    if length $dirty;

my $notes =
    defined $opt{notes}
    ? read_notes( $opt{notes} )
    : { subtitle => $PLACEHOLDER_SUBTITLE, features => $PLACEHOLDER_FEATURES };

my @said;
my @RELEASED_IDS;    # P22: the ids with an entry in the section being released
my %STAMPED;         # SM1454 R6 b: id => 'shipped' | 'partial', for a bullet stamped here
my $CLASSIFICATION;  # dist/config/classification.json, read on first use (runtime_file)
changelog();
filings();
compliance();
archive() if $PAT == 0;
features();
version_pair();
run_tool( 'tools/import-field-practice.pl', '--engine-version', $VERSION, '--date', $DATE );
push @said, "practice briefing re-imported for $VERSION";
run_tool( 'tools/gen-doc-index.pl', '--write' );
push @said, 'doc index regenerated';

# Its own output is inside the allowlist, or it says so before anyone commits it.
# An entry ending in / allows the files below it, as release.sh's outside_of reads it.
my %allowed = map  { $_ => 1 } grep { !m{/\z} } @ALLOWLIST;
my @prefix  = grep { m{/\z} } @ALLOWLIST;
my @outside = grep { my $p = $_; !$allowed{$p} && !grep { index( $p, $_ ) == 0 } @prefix } map { substr $_, 3 }
    split /\n/, git_out( 'status', '--porcelain', '--untracked-files=all' );
refuse("wrote outside the release-material allowlist: @outside") if @outside;

print "release-material: $_\n" for @said;
exit 0;

# --- CHANGELOG ---------------------------------------------------------------

sub changelog {
    my $file  = "$DIR/CHANGELOG.md";
    my @lines = split /\n/, slurp($file), -1;
    my ($u)   = grep { $lines[$_] eq '## Unreleased' } 0 .. $#lines;
    refuse('CHANGELOG.md has no "## Unreleased" heading') unless defined $u;
    refuse("CHANGELOG.md already has a section for $VERSION")
        if grep { /^## \Q$VERSION\E\b/ } @lines;
    my $end = $u + 1;
    $end++ while $end <= $#lines && $lines[$end] !~ /^## /;
    refuse('the Unreleased section has no entries - there is nothing to release')
        unless grep { /^- / } @lines[ $u + 1 .. $end - 1 ];

    my @refused;
    my $stamped = 0;
    for my $i ( $u + 1 .. $end - 1 ) {
        next unless $lines[$i] =~ /^- \S.*?\s\(PENDING\)/;
        my ( $sha, $why ) = landed_sha( $lines[$i], \@lines );
        if ( !$sha ) { push @refused, "  $lines[$i]\n    $why"; next }
        $lines[$i] =~ s/^(- \S.*?\s)\(PENDING\)/$1($sha)/;
        $stamped++;

        # SM1454 R6 b: what the stamp says the bullet shipped. A bullet that names a
        # part of a filing - `SM1454 (R3)`, `SM1369 X4`, `SM12 partial` - is partial.
        if ( $lines[$i] =~ /^- (SM\d+[a-z]?(?:[ ,\/+&]+SM\d+[a-z]?)*)(.*?)\s\(\Q$sha\E\)/ ) {
            my ( $ids, $qual ) = ( $1, $2 );
            my $kind = $qual =~ /\(\s*[A-Z]{1,2}\d+|\b[A-Z]\d+\b|\bpart(?:ial)?\b/ ? 'partial' : 'shipped';
            # One part among the bullets keeps the filing partial.
            for my $id ( $ids =~ /(SM\d+[a-z]?)/g ) {
                $STAMPED{$id} = $kind unless ( $STAMPED{$id} // '' ) eq 'partial';
            }
        }
    }
    # P22: the filings these entries close are stamped with the version below.
    for my $i ( $u + 1 .. $end - 1 ) {
        next unless $lines[$i] =~ /^- (SM\d+[a-z]?(?:[ ,\/+&]+SM\d+[a-z]?)*)\s/;
        push @RELEASED_IDS, $1 =~ /(SM\d+[a-z]?)/g;
    }

    refuse( "a PENDING ref cannot be resolved unambiguously - stamp these by hand on main:\n"
            . join( "\n", @refused ) )
        if @refused;

    my $heading = sprintf '## %s - %s: %s (%s)', $VERSION, uc $opt{channel}, $notes->{subtitle}, $DATE;
    splice @lines, $u, 1, '## Unreleased', '', $heading;
    spit( $file, join "\n", @lines );
    push @said, "CHANGELOG: $heading", "CHANGELOG: $stamped PENDING ref(s) stamped with landed SHAs";
    return;
}

# The commit, since the newest tag reachable from HEAD, whose diff added this
# exact line to CHANGELOG.md - or undef and the reason.
sub landed_sha {
    my ( $line, $all ) = @_;
    my $copies = grep { $_ eq $line } @$all;
    return ( undef, "the same line appears $copies times in CHANGELOG.md" ) if $copies > 1;

    my $tag = git_out( 'describe', '--tags', '--abbrev=0', '--match', 'v[0-9]*', 'HEAD' );
    my $range = $tag ? "$tag..HEAD" : 'HEAD';
    my @cand = split /\n/, git_out( 'log', '--format=%H', "-S$line", $range, '--', 'CHANGELOG.md' ) // '';
    my @added = grep {
        my $sha = $_;
        grep { $_ eq "+$line" } split /\n/,
            git_out( 'show', '--format=', '--no-color', '-U0', $sha, '--', 'CHANGELOG.md' ) // ''
    } @cand;
    return ( undef, 'no commit in ' . $range . ' added this line' ) unless @added;
    return ( undef, scalar(@added) . ' commits added this exact line: ' . join ' ', map { substr $_, 0, 8 } @added )
        if @added > 1;
    return ( substr( $added[0], 0, 8 ), undef );
}

# --- the filings -------------------------------------------------------------

# P22 (WORK-PLAN-0154, ruled 2026-10-12): A FILING SAYS WHICH RELEASE SHIPPED IT.
# A filing is written with `status-note: "SHIPPED (PENDING): ..."` on its branch,
# because the release is not known there - and nothing ever said which release,
# so 31 filings went on saying PENDING after theirs shipped. Here the release is
# known: every filing in docs/feature-requests/ whose `id:` has an entry in the
# section being released, and whose status-note still begins
# `SHIPPED (PENDING)`, is stamped `SHIPPED (X.Y.Z)`. Nothing else in a filing is
# touched; a filing whose id has no entry here is left for the release that
# names it.
sub filings {
    my %released = map { ( $_ => 1 ) } @RELEASED_IDS;
    return unless %released;
    my $dir = "$DIR/docs/feature-requests";
    opendir my $dh, $dir or return;
    my @files = sort grep { /\.md\z/ } readdir $dh;
    closedir $dh;
    my ( $stamped, $moved ) = ( 0, 0 );
    for my $name (@files) {
        my $path = "$dir/$name";
        my $text = slurp($path);
        my ($fm) = $text =~ /\A---\n(.*?)\n---\n/s      or next;
        my ($id) = $fm   =~ /^id:\s*(SM\d+[a-z]?)\s*$/m or next;
        next unless $released{$id};
        my $new = $fm;

        # SM1454 R6 b: a candidate whose bullet is stamped with its landed SHA here is
        # not a candidate any more. t/lint/26 fails a released claim on a `candidate`,
        # and 0.17.1 learned that after a 33-minute suite and a branch of its own.
        if ( $STAMPED{$id} && $new =~ /^status:\s*candidate\s*$/m ) {
            my $partial = $STAMPED{$id} eq 'partial';
            my $says    = ( $partial ? 'PARTIALLY SHIPPED' : 'SHIPPED' ) . " ($VERSION)";
            $new =~ s/^status:\s*candidate\s*$/status: @{[ $partial ? 'partial' : 'shipped' ]}/m;
            if ( $new =~ /^status-note:\s*"(.*)"\s*$/m ) {
                my $note = $1;
                # A note a branch already wrote as SHIPPED (PENDING) is stamped below.
                unless ( $note =~ /^(?:PARTIALLY )?SHIPPED \(PENDING\)/ ) {
                    $note =~ s{^OPEN\b [.:;]? \s* (?: Target [ ] \S+ (?: [ ] (?:stable|beta|edge) )? \. \s* )?}{}x;
                    $note = length $note ? "$says: $note" : "$says.";
                    $new =~ s/^status-note:.*$/'status-note: "' . $note . '"'/me;
                }
            }
            else {
                my $note = $partial ? "$says: the CHANGELOG entry names the part." : "$says.";
                $new =~ s/^(status:.*)$/$1\nstatus-note: "$note"/m;
            }
            $moved++;
        }

        $new =~ s/^(status-note:\s*"SHIPPED )\(PENDING\)/$1($VERSION)/m
            and $stamped++;
        next if $new eq $fm;
        $text =~ s/\A---\n\Q$fm\E\n---\n/---\n$new\n---\n/s or next;
        spit( $path, $text );
    }
    push @said, "filings: $stamped status-note(s) stamped SHIPPED ($VERSION)";
    push @said, "filings: $moved candidate(s) moved to shipped or partial" if $moved;
    return;
}

# --- the compliance records of a patch (SM1454 R6 a, R7) ---------------------

# 0.17.1 was one line in the auth wrapper, and its gate stopped at the compliance
# check: OBLIGATIONS.md (reviewed_at_version) and TECHNICAL-FILE.md (covers_version)
# still said 0.17.0, so a branch of its own walked them by hand (SM1456) and was
# landed before the gate could start again. For a PATCH the walk is mechanical, and
# this does it, in the gate's stage and in the build's release commit alike:
#
#   - a STABLE, EDGE or BETA patch X.Y.Z (Z > 0) of the line's newest earlier release
#     (the base, vX.Y.Z-1 or below, whatever channel it was cut on: R7, ruling 262)
#     whose two records say they were reviewed AT THAT BASE: both are stamped
#     with the target, OBLIGATIONS.md's reviewed_on with the date, and a dated
#     patch-walk clause (it names the channel: "a **stable patch**", "an **edge
#     patch**") says what the diff from the base changes - the RUNTIME files
#     (dist/config/classification.json decides: a file the manifest ships is runtime,
#     the tooling, tests and docs it excludes are not) and the register entries
#     docs/SECURITY.md gains. The clause is f0226a873's form.
#   - REFUSED, nothing written, when a runtime file changed and the diff adds no
#     register entry naming an SM number (the change was not assessed; ADR 0007), or
#     when a record was not reviewed at the base (a patch of a walk nobody made).
#   - LEFT FOR THE CHECK when the cut is certified or a new minor (X.Y.0), on any
#     channel: those claim a walk by hand, so the records are not touched and the compliance check,
#     which runs next and still honours docs/compliance/SIGNOFF.md, names them.
#   - A record already at the target was walked by hand: left as it is. A tree with
#     no compliance records is not touched.
#
# It stamps that the diff was read against the register; it does not read the rows.
# The clause says so, and the rows the diff does not touch stand as walked at the base.
sub compliance {
    return unless grep { $opt{channel} eq $_ } qw(stable edge beta certified);
    my @records = (
        [ 'docs/compliance/OBLIGATIONS.md',    'reviewed_at_version' ],
        [ 'docs/compliance/TECHNICAL-FILE.md', 'covers_version' ],
    );
    return unless grep { -f "$DIR/$_->[0]" } @records;

    my @behind;
    for my $r (@records) {
        my ( $rel, $key ) = @$r;
        refuse("$rel is missing; it is walked by hand") unless -f "$DIR/$rel";
        my ($at) = slurp("$DIR/$rel") =~ /^\s*\Q$key\E:\s*["']?(\d+\.\d+\.\d+)/m;
        refuse("$rel has no $key; it is walked by hand") unless defined $at;
        push @behind, [ $rel, $key, $at ] if vcmp( $at, $VERSION ) < 0;
    }
    return unless @behind;

    my $base = patch_base();
    if ( $opt{channel} eq 'certified' || $PAT == 0 || !defined $base ) {
        push @said, 'compliance: the records are behind '
            . $VERSION . ' and this cut is '
            . ( $opt{channel} eq 'certified' ? 'a certified cut' : $PAT == 0 ? 'a new minor' : 'a patch with no earlier release of its line' )
            . ': walk them by hand (the compliance check says which)';
        return;
    }
    ( my $bv = $base ) =~ s/^v//;
    my $kind  = ( $opt{channel} eq 'edge' ? 'an' : 'a' ) . " $opt{channel} patch";
    my $kindb = ( $opt{channel} eq 'edge' ? 'an' : 'a' ) . " **$opt{channel} patch**";
    for my $r (@behind) {
        my ( $rel, $key, $at ) = @$r;
        refuse( "$rel says $key $at, not $bv, the release this patch is of: it was not walked at the base, "
                . "so there is no walk to carry forward. Walk it by hand for $bv or this cut, then cut again." )
            if vcmp( $at, $bv ) != 0;
    }

    my @files   = split /\n/, git_out( 'diff', '--name-only', $base, 'HEAD' ) // '';
    my @runtime = grep { runtime_file($_) } @files;
    my @entries = register_entries($base);
    refuse( "a runtime file changed since $base and the diff adds no entry to the significant-change register "
            . "(docs/SECURITY.md '### DATE - SMNNNN ...'): " . join( ', ', @runtime[ 0 .. ( $#runtime < 4 ? $#runtime : 4 ) ] )
            . ( @runtime > 5 ? ", and @{[ @runtime - 5 ]} more" : '' )
            . ". A change a site runs is assessed against the ADR 0007 triggers before it ships." )
        if @runtime && !@entries;

    my $files = @runtime ? join( ', ', map { "`$_`" } @runtime ) : 'none - the diff changes nothing a site runs';
    my $regs = @entries ? join( '; ', @entries ) : 'none';
    my $diff = scalar(@files) . ' file' . ( @files == 1 ? '' : 's' );

    my %done;
    for my $r (@behind) {
        my ( $rel, $key ) = @$r;
        my $path = "$DIR/$rel";
        my $text = slurp($path);
        $text =~ s/^(\s*\Q$key\E:\s*)\S+/$1$VERSION/m or refuse("$rel: cannot stamp $key");
        if ( $key eq 'reviewed_at_version' ) {
            $text =~ s/^(\s*reviewed_on:\s*)\S+/$1$DATE/m or refuse("$rel: has no reviewed_on to stamp");
            my $section = "# Walked for $VERSION: what a person must confirm\n\n"
                . "Patch-walked on $DATE by tools/release-material.pl for $VERSION, $kindb of $bv, against the\n"
                . "diff alone (`git diff $base HEAD`, $diff). Runtime files it changes: $files.\n"
                . "Register entries it carries: $regs. The stamp says the diff was read against the register,\n"
                . "not that a row was re-read: every row the diff does not touch stands as walked for $bv.\n\n";
            $text =~ s/^(?=# Walked for )/$section/m or $text =~ s/\n*\z/\n\n$section/;
            $text =~ s/\n+\z/\n/;
        }
        else {
            my $clause = "patch-walked on $DATE against $VERSION, $kind of $bv (the diff from $base: runtime files: "
                . ( @runtime ? join( ', ', @runtime ) : 'none' ) . "; register entries: $regs); ";
            $text =~ s/^(status:\s+index - complete in coverage, )/$1$clause/m
                or refuse("$rel: its status line is not 'index - complete in coverage, ...'; walk it by hand");
        }
        spit( $path, $text );
        $done{$rel} = 1;
    }
    push @said, sprintf 'compliance: patch-walked %s for %s against %s (%s runtime file%s, %d register entr%s)',
        join( ' and ', map { s{.*/}{}r } sort keys %done ), $VERSION, $base,
        scalar(@runtime), @runtime == 1 ? '' : 's', scalar(@entries), @entries == 1 ? 'y' : 'ies';
    return;
}

# The newest release tag of this version's line below it - v0.17.0 for 0.17.1 - or undef.
sub patch_base {
    my @tags = grep { /\Av\Q$MAJ.$MIN\E\.\d+\z/ && vcmp( substr( $_, 1 ), $VERSION ) < 0 }
        split /\n/, git_out( 'tag', '-l', "v$MAJ.$MIN.*" ) // '';
    my ($newest) = sort { vcmp( substr( $b, 1 ), substr( $a, 1 ) ) } @tags;
    return $newest;
}

sub vcmp {
    my ( $x, $y ) = map { [/(\d+)/g] } @_;
    for my $i ( 0 .. 2 ) {
        my $c = ( $x->[$i] // 0 ) <=> ( $y->[$i] // 0 );
        return $c if $c;
    }
    return 0;
}

# The headings the diff from BASE adds to docs/SECURITY.md's register that name an SM
# number: '2026-11-16 - SM1455 (PENDING): the bad-URL guard ...'.
sub register_entries {
    my ($base) = @_;
    my $diff = git_out( 'diff', '-U0', '--no-color', $base, 'HEAD', '--', 'docs/SECURITY.md' ) // '';
    return grep { /\bSM\d+/ } map { /^\+### (\d{4}-\d{2}-\d{2} .*)$/ ? $1 : () } split /\n/, $diff;
}

# Is this path one a site runs? dist/config/classification.json decides, as
# tools/build-manifest.pl reads it: a root dotfile and every `exclude` pattern are
# tooling and docs; a path an override or a rule classifies ships; a path nothing
# classifies is counted as runtime, because the manifest build would refuse it.
sub runtime_file {
    my ($rel) = @_;
    unless ($CLASSIFICATION) {
        my $p = "$DIR/dist/config/classification.json";
        require JSON::PP;
        $CLASSIFICATION = eval { JSON::PP::decode_json( slurp($p) ) }
            or refuse("cannot read $p to tell a runtime file from tooling: $@");
    }
    return 0 if $rel =~ m{\A\.[^/]*\z};
    for my $pat ( @{ $CLASSIFICATION->{exclude} // [] } ) { return 0 if $rel =~ /$pat/ }
    return 1;
}

# --- the archive, at a new minor ---------------------------------------------

sub archive {
    my $file = "$DIR/CHANGELOG.md";
    my ( $head, @sections ) = split /^(?=## )/m, slurp($file);
    my ( @keep, @move );
    for my $s (@sections) {
        if ( $s =~ /\A## (\d+)\.(\d+)\.\d+\b/ && "$1.$2" ne "$MAJ.$MIN" ) { push @move, $s }
        else { push @keep, $s }
    }
    return unless @move;
    my $moved = join '', @move;
    $moved .= "\n" unless $moved =~ /\n\n\z/;
    my $arch = "$DIR/docs/releases/CHANGELOG-archive.md";
    my $text = slurp($arch);
    $text =~ s/\A(---\n.*?\n---\n\n)/$1$moved/s
        or refuse('docs/releases/CHANGELOG-archive.md has no front matter to insert below');
    my $kept = join '', $head, @keep;
    $kept =~ s/\n+\z/\n/;
    spit( $arch, $text );
    spit( $file, $kept );
    push @said, sprintf 'archive: %d section(s) of earlier minors moved to CHANGELOG-archive.md',
        scalar @move;
    return;
}

# --- FEATURES ----------------------------------------------------------------

sub features {
    my $file = "$DIR/docs/FEATURES.md";
    my $text = slurp($file);
    refuse("docs/FEATURES.md already has a timeline entry for $VERSION")
        if $text =~ /^- \*\*\Q$VERSION\E\*\*/m;
    my $title = ucfirst $notes->{subtitle};
    $title .= '.' unless $title =~ /[.!?]\z/;
    local $Text::Wrap::columns  = 80;
    local $Text::Wrap::huge     = 'overflow';
    local $Text::Wrap::unexpand = 0;
    my $entry = wrap( '- ', '  ', "**$VERSION** ($DATE, $opt{channel}) - **$title** $notes->{features}" );
    $text =~ s/^(Newest first; releases are git tags\.\n\n)/$1$entry\n/m
        or refuse('docs/FEATURES.md has no "Newest first; releases are git tags." line to add under');
    $text =~ s/(as of v)\d+\.\d+\.\d+/$1$VERSION/;
    spit( $file, $text );
    push @said, "FEATURES: timeline entry for $VERSION, subtitle as of v$VERSION";
    return;
}

# --- VERSION and NEXT_VERSION, by the tool that owns the pair ---------------

sub version_pair {
    spit( "$DIR/NEXT_VERSION", "$VERSION\n" );    # bump-version promotes it ...
    run_tool('tools/bump-version.pl');            # ... and advances the patch
    push @said, sprintf 'VERSION %s, NEXT_VERSION %s', map { my $v = slurp("$DIR/$_"); chomp $v; $v }
        qw(VERSION NEXT_VERSION);
    return;
}

# --- the notes file ----------------------------------------------------------

sub read_notes {
    my ($path) = @_;
    my $text = slurp($path);
    my ( $header, $body ) = split /^\s*\n/m, $text, 2;
    my ( %h, @order, $key );
    for my $l ( split /\n/, $header // '' ) {
        if ( my ( $name, $value ) = $l =~ /^([A-Za-z-]+):\s*(.*)$/ ) {
            $key = lc $name;
            refuse("notes $path: unknown header '$name' (Subtitle, Features, Assisted-by, Claude-Session)")
                unless $key =~ /\A(?:subtitle|features|assisted-by|claude-session)\z/;
            push @order, $name unless exists $h{$key};
            $h{$key} = $value;
        }
        elsif ( $l =~ /^\s+(\S.*)$/ && defined $key ) { $h{$key} .= " $1" }
        else { refuse("notes $path: '$l' is not a header line - the header ends at the first blank line") }
    }
    for my $need (qw(subtitle features)) {
        refuse("notes $path: no '\u$need:' header") unless length( $h{$need} // '' );
    }
    my @trailers = map { "$_: $h{ lc $_ }" } grep { /\A(?:Assisted-by|Claude-Session)\z/i } @order;
    return {
        subtitle   => $h{subtitle},
        features   => $h{features},
        trailers   => \@trailers,
        annotation => $body // '',
    };
}

# --- the build's checks ------------------------------------------------------

sub resolve_lints {
    my $dir = defined $opt{dir} ? abs_path( $opt{dir} ) : dirname( dirname( abs_path($0) ) );
    my @out;
    for my $p (@LINTS) {
        my @f = glob "$dir/$p*.t";
        refuse( "no single test file for $p in $dir (found " . scalar(@f) . ')' ) unless @f == 1;
        push @out, substr $f[0], length("$dir/");
    }
    return @out;
}

# --- helpers -----------------------------------------------------------------

sub run_tool {
    my ( $tool, @args ) = @_;
    my $here = getcwd();
    chdir $DIR or refuse("cannot enter $DIR: $!");
    my $out = qx{$^X \Q$DIR/$tool\E @{[ map { quotemeta } @args ]} 2>&1};
    my $rc  = $?;
    chdir $here or refuse("cannot return to $here: $!");
    refuse("$tool failed:\n$out") if $rc;
    return;
}

sub git_out {
    my (@args) = @_;
    # git's own complaints (describe with no tag) are answered by the caller.
    open my $err, '>&', \*STDERR    or die "dup STDERR: $!\n";
    open STDERR,  '>',  '/dev/null' or die "STDERR: $!\n";
    my $ok = open my $g, '-|', 'git', '-C', $DIR // dirname( dirname( abs_path($0) ) ), @args;
    my $out = $ok ? do { local $/; <$g> } // '' : '';
    $ok &&= close $g;
    open STDERR, '>&', $err or die "restore STDERR: $!\n";
    return undef unless $ok;
    $out =~ s/\n\z//;
    return $out;
}

sub slurp {
    my ($p) = @_;
    open my $f, '<', $p or refuse("cannot read $p: $!");
    local $/;
    my $t = <$f>;
    close $f;
    return $t;
}

sub spit {
    my ( $p, $t ) = @_;
    open my $f, '>', "$p.new.$$" or refuse("cannot write $p: $!");
    print {$f} $t;
    close $f or refuse("cannot write $p: $!");
    rename "$p.new.$$", $p or refuse("cannot replace $p: $!");
    return;
}

sub refuse {
    my ($why) = @_;
    print STDERR "release-material: REFUSED - $why\n";
    exit 1;
}

sub usage {
    my ($why) = @_;
    print STDERR "release-material: $why\n" if defined $why;
    print STDERR "usage: release-material.pl VERSION --dir DIR [--channel C] [--notes FILE] [--date D]\n"
        . "       release-material.pl --paths | --lints [--dir DIR]"
        . " | --notes FILE --print annotation|trailers|subtitle\n";
    exit 2;
}
