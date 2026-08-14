#!/usr/bin/perl
# Every front-matter key ADR 0008 freezes must actually exist.
#
# WHY. `docs/adr/0008-stable-compatibility-freeze.md` lists the front-matter
# fields whose "name, meaning, type and default" are frozen for the stable line.
# It is the document a reader consults to learn what will NOT change, so it
# carries more weight than most - and it listed `meta_title` and `meta_desc`,
# neither of which existed anywhere in the codebase (SM300). A compatibility
# freeze naming fields that were never implemented is worse than an ordinary
# documentation error: it is a promise about behaviour that has no behaviour
# behind it.
#
# Found by a site agent reading the ADR to work out why a page had no meta
# description. Both fields have since been implemented, which is one way to make
# the document true; this test is the other half, so the next entry added to
# that list has to be real.
#
# Same class as t/lint/36 - a factual table in a reference document, asserted
# against the source rather than trusted.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

my $adr = "$root/docs/adr/0008-stable-compatibility-freeze.md";
ok( -f $adr, 'ADR 0008 is present' ) or do { done_testing; exit };

my $text = slurp($adr);

# The frozen page-front-matter list. Taken from the bullet under the "Page front
# matter" heading rather than the whole document, so an unrelated backtick
# elsewhere in the ADR cannot be mistaken for a frozen key.
# Bullet 2 ONLY, stopping at bullet 3. The first cut of this ran to the next
# blank line and swallowed the LAYOUT CONTRACT bullet, then reported `whoami` as
# a missing front-matter field - a test inventing its own finding.
my ($section) = $text =~ /^\d+\.\s+\*\*Page front\s*matter\*\*(.*?)^\d+\.\s+\*\*/ms;
ok( $section, 'the ADR names its frozen page front-matter fields' )
    or do { done_testing; exit };

my %claimed;
while ( $section =~ /`([a-z_]+)(?:\/`?([a-z_]+)`?)?`/g ) {
    $claimed{$1} = 1;
    $claimed{$2} = 1 if defined $2 && length $2;
}
cmp_ok( scalar keys %claimed, '>=', 8, 'parsed the frozen field list' )
    or diag( join ', ', sort keys %claimed );

# Where a front-matter key is actually read. The processor is the reader that
# matters; the registry builders and templates consume what it resolves.
# Every engine reader, not just the processor: `translated_from` is read by
# Lazysite::Lang, and a haystack that missed it reported a field that has worked
# since SM179 as absent.
my @readers = ( "$root/lazysite-processor.pl", glob("$root/lib/Lazysite/*.pm"),
    glob("$root/lib/Lazysite/*/*.pm") );
# COMMENTS STRIPPED, so a field that is only ever discussed in a comment cannot
# satisfy the check - which would defeat the point, since the ADR entry is
# itself a description of a field nobody implemented.
my $haystack = join "\n",
    map { join "\n", grep { !/^\s*#/ } split /\n/, slurp($_) }
    grep { -f $_ } @readers;

subtest 'every frozen front-matter key is read somewhere' => sub {
    my @missing;
    for my $key ( sort keys %claimed ) {
        # Three shapes, because the engine reads front matter three ways:
        # `$meta->{key}` in the processor, `key =>` passed through into a page or
        # registry hash, and a regex literal - Lazysite::Lang reads
        # `translated_from` with /^translated_from\h*:/ and matches neither of
        # the first two.
        push @missing, $key
            unless $haystack =~ /\{\s*\Q$key\E\s*\}/
            || $haystack     =~ /\b\Q$key\E\s*=>/
            || $haystack     =~ /\^\Q$key\E\\h\*:/;
    }

    is_deeply( \@missing, [],
        'ADR 0008 freezes only fields that exist' )
        or diag( join "\n  ",
        '',
        @missing,
        '',
        'The compatibility freeze promises these will not change, and nothing',
        'reads them - so there is no behaviour to keep stable. Either implement',
        'the field or remove it from the ADR; do not leave a promise with',
        'nothing behind it.' );
};

done_testing();
