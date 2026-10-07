#!/usr/bin/perl
# SM946: THE RECORDS STAY SHORT, SO THEY STAY CHEAP TO READ AND CHECK.
#
# CHANGELOG.md had grown to 1 MB and 15,600 lines; the lint that checks its
# commit refs took 57 s and set the floor under every handoff. Filing status
# notes averaged 2.8 KB on a single line. Both are read, by agents and by lints,
# far more often than they are written.
#
#   1. CHANGELOG.md holds only the current minor line (VERSION's or
#      NEXT_VERSION's minor) and Unreleased. Earlier sections live, unchanged, in
#      docs/releases/CHANGELOG-archive.md; the post-release step that names a
#      new minor's first section moves the previous minor there.
#   2. A filing raised from 2026-10-07 keeps its status-note to 400 characters;
#      the detail belongs in the filing body. Earlier filings are left as written.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root changelog_text);

my $root = repo_root();
sub first_line { open my $f, '<', $_[0] or return ''; my $l = <$f>; close $f; chomp $l if defined $l; $l // '' }
my %minor = map { ( /^(\d+\.\d+)\./ ? ( $1 => 1 ) : () ) }
    first_line("$root/VERSION"), first_line("$root/NEXT_VERSION");

subtest 'the live changelog is one minor line long' => sub {
    my @old = grep { /^(\d+\.\d+)\./ && !$minor{$1} }
        ( changelog_text() =~ /^## (\d+\.\d+\.\d+)\b/mg );
    is_deeply( \@old, [], 'no section from an earlier minor in CHANGELOG.md' )
        or diag( 'Move these sections, unchanged, to the top of '
            . 'docs/releases/CHANGELOG-archive.md (below its front matter).' );
    like( changelog_text( history => 1 ), qr/^## 0\.4\.0\b/m,
        'and the archive is read as history, back to the first sections' );
};

subtest 'a new filing keeps its status-note short' => sub {
    my @long;
    for my $f ( glob "$root/docs/feature-requests/SM*.md" ) {
        open my $fh, '<:utf8', $f or next;
        my $t = do { local $/; <$fh> };
        close $fh;
        my ($raised) = $t =~ /^raised: (\d{4}-\d{2}-\d{2})/m;
        next unless $raised && $raised ge '2026-10-07';
        my ($note) = $t =~ /^status-note: "(.*)"$/m;
        push @long, sprintf( '%s (%d chars)', $f =~ s{.*/}{}r, length $note )
            if defined $note && length $note > 400;
    }
    is_deeply( \@long, [], 'status-notes of filings raised from 2026-10-07 are 400 characters or fewer' );
};

done_testing();
