#!/usr/bin/perl
# SM1210: NO TEST WRITES THE CHECKOUT'S VERSION, CHANGELOG OR MANIFEST.
#
# THE CLASS. t/tools/52 wrote 99.0.0 into the tracked VERSION for the length of
# its run. preserve_tracked puts a file back and serialises the tests that ask
# for it, but a test that only READS VERSION asks for nothing: under prove -j it
# saw 99.0.0 (SM1208: t/tools/29 failed the nightly). Locking the readers one at
# a time leaves the next reader to find the same window. The fix is that the
# window does not exist: a test that needs a different VERSION builds its own
# tree and writes there.
#
# WHAT THIS HOLDS. No .t file under t/ opens VERSION, NEXT_VERSION, CHANGELOG.md
# or MANIFEST of the repo root for writing, or writes, removes, moves or copies
# onto it, through a path written from the repo root ($root, $ROOT, $repo,
# repo_root()) - directly or through a variable that holds that path.
# preserve_tracked is NOT an excuse for these four files: it puts a file back
# and serialises the tests that ask for it, which is what did not help the
# readers. Work on a copy.
#
# A source scan, line by line, comments skipped. It does not follow a path built
# in pieces; it finds the spelling every writer so far has used, and it proves
# it still finds it by running on the shape t/tools/52 had.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

my $ROOTVAR = qr/\$(?:root|ROOT|repo|REPO|repo_root|checkout)\b|\$\{\s*(?:root|ROOT|repo)\s*\}|repo_root\(\)/;
my $TRACKED = qr/(?:NEXT_)?VERSION|CHANGELOG\.md|MANIFEST/;
my $PATH    = qr/["']?(?:$ROOTVAR)\/$TRACKED["']?/;
my $WRITER  = qr/\b(?:write_file|spit|unlink|move|copy|rename|truncate)\b/;

# Returns [line, text] for each write of a tracked root file in $source.
sub findings {
    my ($source) = @_;
    my @lines    = split /\n/, $source;
    my %alias;
    for (@lines) {
        next           if /^\s*#/;
        $alias{$1} = 1 if /(?:my\s+)?\$(\w+)\s*=\s*$PATH\s*;/;
    }
    my $alias = join '|', map { quotemeta } sort keys %alias;
    my $VAR   = length $alias ? qr/\$(?:$alias)\b/ : qr/(?!)/;
    my $TGT   = qr/(?:$PATH|$VAR)/;

    my @hit;
    for my $i ( 0 .. $#lines ) {
        my $l = $lines[$i];
        next if $l =~ /^\s*#/;
        if ( $l =~ /\bopen\b[^;]*['"](?:>>?|\+<|\+>)['"]\s*,\s*\{?\s*$TGT/
            || $l =~ /\bopen\b[^;]*['"]?(?:>>?)\s*$TGT/
            || $l =~ /$WRITER\b[^;]*$TGT/ )
        {
            push @hit, [ $i + 1, $l ];
        }
    }
    return @hit;
}

# The scan must still see the shape that was the bug.
{
    my $old = <<'OLD';
my $vf   = "$root/VERSION";
write_file( $vf, "99.0.0\n" );
OLD
    my @h = findings($old);
    is( scalar @h, 1, 'finds a write through a variable holding the VERSION path' );

    @h = findings(q{open my $fh, '>', "$ROOT/VERSION" or die;});
    is( scalar @h, 1, 'finds a three-argument open for writing' );

    @h = findings(q{open my $fh, '<', "$root/VERSION" or die;});
    is( scalar @h, 0, 'a read is not a finding' );

    @h = findings( $old . qq{my \$k = preserve_tracked(\$vf);\n} );
    is( scalar @h, 1, 'preserve_tracked does not excuse it' );

    @h = findings(q{write_file( "$d/VERSION", "1\n" );});
    is( scalar @h, 0, 'a scratch tree is not the checkout' );
}

my $self  = $FindBin::Script;
my @files = split /\n/, `find \Q$root\E/t -name '*.t' -type f | sort`;
ok( scalar @files > 100, 'the scan sees the test tree' );

for my $f (@files) {
    next if $f =~ m{/\Q$self\E\z};
    open my $fh, '<', $f or die "$f: $!";
    local $/;
    my $src = <$fh>;
    close $fh;
    my @h = findings($src);
    ( my $rel = $f ) =~ s{^\Q$root\E/}{};
    ok( !@h, "$rel writes no tracked file of the checkout" )
        or diag( join "\n", map { "  line $_->[0]: $_->[1]" } @h ),
        diag( "Work on a copy: build a scratch tree (TestHelper::site_tempdir) "
            . "and point the tool at it. t/tools/52 shows how." );
}

done_testing();
