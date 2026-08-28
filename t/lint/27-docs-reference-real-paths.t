#!/usr/bin/perl
# SM254: a path named in the documentation must exist in the tree.
#
# A docs audit against v0.9.15 found fourteen divergences between the docs and
# the engine. None dangerous; together they mean the documentation cannot be
# trusted without opening the source, which is the work it exists to save. Two of
# the fourteen were dead paths - `uninstall.sh` and `starter/registries/` are
# referenced and do not exist - and those are the ones a machine can catch. This
# would have failed the day each was removed.
#
# t/lint/01-stale-paths.t is NOT this: it greps a hand-listed set of files for
# one specific literal left behind by the D013 rename. Useful, and narrow.
#
# SCOPE, deliberately conservative. Only paths that are unambiguously
# REPO-relative are checked - a token opening with one of the repo's own
# top-level directories, or a shell script named bare. Documentation is full of
# paths that SHOULD NOT exist here: install targets under /var/www, a site's own
# content, placeholder hostnames. Checking those would produce noise, and a lint
# that cries wolf gets disabled.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);
use File::Find ();

my $root = repo_root();

# The docs a reader actually follows. Feature-request filings are excluded: they
# describe proposals, and routinely name paths that do not exist yet or no longer
# do - that is their job.
my @DOCS;
File::Find::find(
    {   no_chdir => 1,
        wanted   => sub {
            return unless /\.md\z/;
            return if $File::Find::name =~ m{/feature-requests/};
            push @DOCS, $File::Find::name;
        },
    },
    "$root/docs",
    "$root/starter/docs",
);
# NOT the CHANGELOG. It is a historical record, and an entry describing what
# 0.4.0 shipped correctly names files that existed then and do not now. Rewriting
# history to satisfy a lint would be the wrong repair.
push @DOCS, grep { -f } map {"$root/$_"} qw(README.md DEVELOPER.md);

ok( scalar @DOCS, 'found documentation to check' );

# A repo-relative path: opens with one of our own top-level directories.
my $REPO_DIR = qr{(?:tools|lib|plugins|debian|starter|installers)};

# A path is checked only when it LOOKS like a file or a directory: it carries an
# extension, or ends in a slash. Without that the check fires on prose that
# merely contains a slash, and on names that are not paths at all - `tools/list`
# and `tools/call` are JSON-RPC METHOD names, and "plugins / handlers /
# form-targets" is a sentence.
my $LOOKS_LIKE_PATH = qr{(?:\.[A-Za-z0-9*]+\z|/\z)};

# Runtime state under starter/lazysite/ - a site's own config, cache and logs.
# These are gitignored and exist only in a working checkout, so testing for them
# on disk makes the result depend on whether anyone has run the dev server. The
# docs name them precisely BECAUSE they are operator-written or generated: the
# rsync recipe lists them as things NOT to sync.
#
# This is the same portability fault as the absolute-path exclusion below, found
# the same way: the lint passed in the primary checkout and failed in a clean
# worktree. A lint whose verdict depends on leftover state is worse than none.
my $RUNTIME_STATE = qr{\Astarter/lazysite/(?:cache|logs|auth)/
    | \Astarter/lazysite/(?:lazysite|nav)\.conf\z
    | \Astarter/lazysite/forms/}x;

my %EXEMPT_TOKEN = map { $_ => 1 } ();

# Script names a doc may legitimately mention without the repo containing them.
# Each carries its reason: an unexplained exemption is how a lint stops meaning
# anything.
my %EXEMPT_SCRIPT = (
    'lzs-dav.sh' =>
        'the site agent\'s own token helper, named in ai-briefing-practice.md - '
        . 'which is IMPORTED from that agent\'s working notes in another tree '
        . '(tools/import-field-practice.pl) and legitimately describes tooling '
        . 'from its environment rather than this repo\'s. The engine ships '
        . 'bin/lzs-token.sh; this is a different script the agent drives WebDAV '
        . 'with, and the practice page is a record of how the field works, not '
        . 'an index of what this tree contains',
    'rehearsal.sh' =>
        'a one-off disaster-rehearsal script from the 0.7.0 cut, kept in the '
        . 'session records rather than the tree; RELIABILITY.md cites it as '
        . 'provenance for a measurement, not as something to run',
    'pre-release.sh' =>
        'named in development.md as what tools/release.sh REPLACED - a '
        . 'historical statement, and rewriting it would lose the history',
    'make-release.sh' => 'as pre-release.sh',
    'generate-index.sh' =>
        'an example script remote-content.md shows the READER how to write for '
        . 'their own content source; it is sample code, not a shipped file',
);

# Every shell script in the tree, by basename - a doc may name one without
# saying where it lives (installers/hestia/... is referenced bare), so location
# is not the thing being checked here. Existence is.
my %SCRIPTS;
File::Find::find(
    {   no_chdir => 1,
        wanted   => sub {
            return unless /([^\/]+\.sh)\z/;
            # Capture IMMEDIATELY: $1 belongs to the last successful match, and
            # the two regexes below would clobber it before it is read.
            my $base = $1;
            # Match the exclusion against the REPO-RELATIVE path, never the
            # absolute one. The gate runs from a worktree under /srv/tmp, where
            # an absolute match on "tmp" excluded every script in the tree - so
            # the lint reported release.sh, install.sh and coverage.sh as dead
            # references, in a checkout where all three exist. It passed in the
            # primary checkout and failed in the gate: a lint whose result
            # depends on WHERE the repo sits is worse than no lint.
            my $rel_path = $File::Find::name;
            $rel_path =~ s{\A\Q$root\E/}{};
            return if $rel_path =~ m{\A(?:\.git|tmp|dist)/};
            $SCRIPTS{$base} = 1;
        },
    },
    $root,
);

my @dead;
for my $doc (@DOCS) {
    open my $fh, '<:utf8', $doc or die "$doc: $!";
    my $text = do { local $/; <$fh> };
    close $fh;
    ( my $rel = $doc ) =~ s{\A\Q$root\E/}{};

    my %seen;
    while ( $text =~ m{(?<![\w/.-])($REPO_DIR/[\w./*-]+)}g ) {
        my $tok = $1;
        next if $seen{$tok}++;
        $tok =~ s{[.,:;)]+\z}{};      # trailing punctuation from prose
        next unless length $tok;
        next if $EXEMPT_TOKEN{$tok};
        next if $tok =~ $RUNTIME_STATE;
        next unless $tok =~ $LOOKS_LIKE_PATH;

        # A glob stands for its directory.
        my $check = $tok;
        if ( $check =~ m{\*} ) { $check =~ s{/[^/]*\*.*\z}{}; }
        next unless length $check;

        push @dead, "$rel: $tok" unless -e "$root/$check";
    }

    # Bare shell scripts - the uninstall.sh case. Checked against the places a
    # script legitimately lives, so a site-side script named in passing does not
    # trip it.
    %seen = ();
    while ( $text =~ m{(?<![\w/.-])([a-z][\w-]*\.sh)\b}g ) {
        my $tok = $1;
        next if $seen{$tok}++;
        next if $SCRIPTS{$tok} || $EXEMPT_SCRIPT{$tok};
        push @dead, "$rel: $tok";
    }
}

is_deeply( \@dead, [], 'every path named in the docs exists in the tree' )
    or diag( "Referenced but absent:\n  " . join( "\n  ", @dead ) );

done_testing();
