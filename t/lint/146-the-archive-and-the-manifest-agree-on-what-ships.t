#!/usr/bin/perl
# SM884: the release tarball must not contain the previous release.
#
# release.sh packages with `git archive` (tools/release.sh:768), which ships
# every tracked path unless it is marked export-ignore. download/ holds a
# COMPLETE release - a tarball, its digest and four debs - so every release
# shipped a copy of the one before it, and since that copy contains ITS
# predecessor the nesting compounds. Measured on 0.14.1's tree: 34.2 MB of
# archive, 27.7 MB of it download/, against an engine of about 6.5 MB. After
# the export-ignore: 6.48 MB.
#
# WHAT THIS GUARDS IS THE DISAGREEMENT, not the line. The defect was not that
# somebody forgot an attribute - it was that two mechanisms answered "is this
# part of the release?" differently and nothing compared them.
# dist/config/classification.json excludes `^download/` from the release
# manifest, so the installer has never installed these files; the archive
# shipped them anyway. A future directory added to one and not the other is the
# same bug with a different name, so this test asserts the PAIR agrees.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# The directories that are release artefacts ABOUT the project rather than part
# of it. Each must be excluded from both the manifest and the archive.
my @not_part_of_the_release = ('download/');

my $attrs = "$root/.gitattributes";
ok( -f $attrs, '.gitattributes exists' );

open my $ah, '<', $attrs or die $!;
my $attr_text = do { local $/; <$ah> };
close $ah;

open my $ch, '<', "$root/dist/config/classification.json" or die $!;
my $class_text = do { local $/; <$ch> };
close $ch;

for my $dir (@not_part_of_the_release) {
    ( my $bare = $dir ) =~ s{/\z}{};

    like( $attr_text, qr/^\Q$dir\E\s+export-ignore\s*$/m,
        "$dir is export-ignore, so git archive leaves it out of the tarball" );

    like( $class_text, qr/\Q^$bare\/\E/,
        "$dir is excluded from the release manifest, so the installer "
            . 'never installs it' );
}

# ASKED OF GIT, not of the file's text. `git archive` resolves the attribute
# through git's own lookup, so a line that is present but not in force - a
# typo, or an overriding pattern below it - would pass the regex above and
# still ship 27 MB. check-attr performs the same resolution.
#
# THE TRAILING SLASH IS LOAD-BEARING and cost a wrong verdict while this was
# written. `download/ export-ignore` marks the DIRECTORY entry; git then omits
# the whole subtree from the archive, but check-attr answers per path as
# spelled - `download/` is `set`, `download` and `download/README.md` are both
# `unspecified`. A probe on a file inside the directory therefore reports
# nothing while the archive is in fact correct. Verified against the real
# thing: archiving a tree with this attribute produced 6,481,528 bytes and
# zero download/ entries, against 34,185,929 bytes and eight without it.
for my $dir (@not_part_of_the_release) {
    SKIP: {
        skip 'no git checkout here', 1 unless -d "$root/.git";
        my $out = qx{git -C \Q$root\E check-attr export-ignore -- \Q$dir\E 2>&1};
        like( $out, qr/export-ignore:\s*set/,
            "git itself reports export-ignore set for $dir - the attribute is "
                . 'in force, not merely written down' );
    }
}

done_testing();
