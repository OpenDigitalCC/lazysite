#!/usr/bin/perl
# tools/gen-doc-index.pl - generate docs/INDEX.md, the map of the doc estate.
#
#   perl tools/gen-doc-index.pl            # print
#   perl tools/gen-doc-index.pl --write    # write docs/INDEX.md
#
# SM735: 719 markdown files, about 4.3MB. An agent asking "is there a document
# about X" had no answer short of grepping or reading, and reading is a million
# tokens. One generated file answers it.
#
# GENERATED, because a hand-kept index is the thing this codebase has learned
# most often not to build: it drifts, nobody notices, and a reader trusts it
# while it is wrong. t/lint/110 fails when it and the tree disagree.
#
# THE FEATURE REQUESTS ARE NOT LISTED HERE, deliberately. tools/backlog.pl
# already lists them from the status headers t/lint/09 enforces, with --all and
# --json. Duplicating 622 entries into a second lister would create exactly the
# hand-kept second copy this file exists to avoid; the index points at the tool
# instead. Reuse over invention.
use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd            qw(abs_path);

my $ROOT  = dirname( dirname( abs_path($0) ) );
my $OUT   = "$ROOT/docs/INDEX.md";
my $write = grep { $_ eq '--write' } @ARGV;

# What each tree is FOR, in the reader's terms. A list of filenames without
# this is a directory listing, which the reader could already get.
my @TREES = (
    [ 'docs', 'Top-level references: the manuals an operator, developer or implementor reads end to end.' ],
    [ 'docs/adr', 'Architecture decision records. What was decided, and what it rules out.' ],
    [ 'docs/architecture', 'How a part of the system is shaped, and why it is shaped that way.' ],
    [ 'docs/reference', 'Generated references. Do not edit by hand - each names its generator.' ],
    [ 'docs/manager-ui-guide', 'The manager, page by page, as an operator meets it.' ],
    [ 'docs/practice', 'Field notes, maintained by the site agent. Source of the briefing that ships to every site.' ],
    [ 'docs/plans', 'Multi-release workplans: what is sequenced, and what each phase unlocks.' ],
    [ 'docs/compliance', 'The regulatory record. Several are gated by lazysite-compliance.pl at a cut.' ],
    [ 'docs/review', 'Review registers: one row per piece of feedback, with what was done or why not.' ],
    [ 'docs/releases', 'What each release was gated on.' ],
    [ 'starter/docs', 'SHIPPED. Installed into every site and served at /docs/. Written for the site owner and their agent.' ],
);

sub summarise {
    my ($path) = @_;
    open my $fh, '<', $path or return ( undef, undef );
    my $c = do { local $/; <$fh> };
    close $fh;

    my ( $title, $sub );
    if ( my ($fm) = $c =~ /\A---\n(.*?)^---\n/ms ) {
        ($title) = $fm =~ /^title:\s*"?(.*?)"?\s*$/m;
        ($sub)   = $fm =~ /^subtitle:\s*"?(.*?)"?\s*$/m;
        $c =~ s/\A---\n.*?^---\n//ms;
    }
    # Falls back to the first heading, because 48 files carry no front matter -
    # the top-level manuals among them. An index that skipped them would be
    # missing exactly the documents a new reader most needs.
    ($title) = $c =~ /^#\s+(.+?)\s*$/m unless defined $title && length $title;
    unless ( defined $sub && length $sub ) {
        # The whole first PARAGRAPH, then its first sentence. Taking one line
        # gave "Install/first-run is in" - these files are hard-wrapped, so a
        # line is not a thought.
        my ( @para, $started );
        for my $l ( split /\n/, $c ) {
            if ( $l =~ /^\s*$/ ) { last if $started; next }
            next if !$started && $l =~ /^#|^[-*>|]|^```|^:::/;
            last if $started  && $l =~ /^#|^```|^:::/;
            push @para, $l;
            $started = 1;
        }
        my $para = join ' ', @para;
        ($sub) = $para =~ /^(.{20,}?[.!?])(?:\s|$)/;
        $sub //= $para;
    }
    for ( $title, $sub ) {
        next unless defined;
        s/\s+/ /g;
        s/\*\*|`|\[|\]\([^)]*\)//g;
        s/^\s+|\s+$//g;
    }
    $sub = substr( $sub, 0, 150 ) . '...' if defined $sub && length $sub > 150;
    return ( $title, $sub );
}

my @out;
push @out, <<'HEAD';
---
title: "lazysite - the documentation index"
subtitle: "Every document in this repository, what it is for, and where the ones that live elsewhere are. Generated: run tools/gen-doc-index.pl --write after adding or removing a document."
brand: plain
standard-margins: true
---

# How to use this

**Generated file - do not edit by hand.** `tools/gen-doc-index.pl --write`
produces it, and `t/lint/110-the-doc-index-matches-the-tree.t` fails when it and
the tree disagree.

It exists so that an agent can find out what is written down without reading it.
The repository carries about 4.3MB of markdown; this file is the map.

## What is NOT listed here

**The feature requests.** There are several hundred, and they have their own
lister already:

    perl tools/backlog.pl            # open work only
    perl tools/backlog.pl --all      # everything, shipped and superseded
    perl tools/backlog.pl --json     # the same, for tooling

Every one carries a machine-readable `status`, enforced by `t/lint/09`. Search
them by name - the filenames are sentences - or by content with `grep -rl`.

## Documentation that lives outside this repository

- **A site's own published docs.** `starter/docs/` installs into every site and
  is served at `/docs/`. A running site publishes around thirty pages; ask it
  with `describe_capabilities` (under "docs") or read `/docs/` rather than
  assuming a feature is undocumented.
- **The layouts catalogue**, in its own repository, documents layouts and themes.
- **Field practice** is maintained by the site agent and lives here under
  `docs/practice/` - see the README there for who maintains what.

HEAD

my $count = 0;
for my $t (@TREES) {
    my ( $dir, $what ) = @$t;
    my $abs = "$ROOT/$dir";
    next unless -d $abs;
    opendir my $dh, $abs or next;
    my @files = sort grep { /\.md$/ && -f "$abs/$_" } readdir $dh;
    closedir $dh;
    next unless @files;
    push @out, "# $dir\n\n$what\n\n";
    push @out, "| Document | What it is |\n| --- | --- |\n";
    for my $f (@files) {
        next if $f eq 'INDEX.md';
        my ( $title, $sub ) = summarise("$abs/$f");
        $title = $f unless defined $title && length $title;
        $sub //= '';
        $sub   =~ s/\|/-/g;
        $title =~ s/\|/-/g;
        push @out, "| [`$f`]($f) - $title | $sub |\n";
        $count++;
    }
    push @out, "\n";
}

push @out, "---\n\n*$count documents indexed, across "
    . scalar(@TREES)
    . " trees. The feature-request corpus is listed by `tools/backlog.pl`.*\n";

my $doc = join '', @out;
if ($write) {
    open my $fh, '>', $OUT or die "$OUT: $!\n";
    print {$fh} $doc;
    close $fh;
    print "wrote $OUT ($count documents)\n";
}
else { print $doc }
