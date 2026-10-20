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
#   starter/docs/ai-briefing-practice.md
#                  re-imported for X.Y.Z (tools/import-field-practice.pl).
#   docs/INDEX.md  regenerated (tools/gen-doc-index.pl --write).
#   docs/feature-requests/*.md
#                  the status-note of every filing whose id has an entry in the
#                  released section and still says "SHIPPED (PENDING)" says
#                  "SHIPPED (X.Y.Z)" (P22).
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
# main that moved past its gate only through these needs no new gate. The last
# two are written by release.sh itself (the GATE-LOG row, the coverage record).
my @ALLOWLIST = qw(
    CHANGELOG.md
    docs/releases/CHANGELOG-archive.md
    docs/FEATURES.md
    docs/INDEX.md
    starter/docs/ai-briefing-practice.md
    VERSION
    NEXT_VERSION
    docs/releases/GATE-LOG.md
    dist/config/coverage-last.json
    docs/feature-requests/
);

# THE CHECKS THAT READ THOSE FILES - every lint naming one of them (t/lint/214
# keeps this list complete), and the briefing's own unit test. release.sh build
# runs them on the release commit; together they take well under a minute.
my @LINTS = qw(
    t/lint/03- t/lint/08- t/lint/09- t/lint/26- t/lint/27- t/lint/36- t/lint/53-
    t/lint/62- t/lint/63- t/lint/65- t/lint/75- t/lint/89- t/lint/110-
    t/lint/113- t/lint/138- t/lint/145- t/lint/149- t/lint/199- t/lint/207- t/lint/210- t/lint/244-
    t/lint/270-
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
changelog();
filings();
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
    my $stamped = 0;
    for my $name (@files) {
        my $path = "$dir/$name";
        my $text = slurp($path);
        my ($fm) = $text =~ /\A---\n(.*?)\n---\n/s      or next;
        my ($id) = $fm   =~ /^id:\s*(SM\d+[a-z]?)\s*$/m or next;
        next unless $released{$id};
        next unless $fm =~ /^status-note:\s*"SHIPPED \(PENDING\)/m;
        ( my $new = $fm ) =~ s/^(status-note:\s*"SHIPPED )\(PENDING\)/$1($VERSION)/m;
        $text =~ s/\A---\n\Q$fm\E\n---\n/---\n$new\n---\n/s or next;
        spit( $path, $text );
        $stamped++;
    }
    push @said, "filings: $stamped status-note(s) stamped SHIPPED ($VERSION)";
    return;
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
