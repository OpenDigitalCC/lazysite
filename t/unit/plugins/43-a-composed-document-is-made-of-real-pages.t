#!/usr/bin/perl
# SM738: the three faults the 0.11.11 field pass found in the composed PDF.
#
# WHY THE GATE MISSED ALL THREE. t/unit/plugins/41 composes from parts that
# carry no front matter, so the concatenation fault could not appear; and it
# passes no `resolve`, so the private-store fault could not either. The fixtures
# described a shape the feature is not for - "compose a document out of pages
# that already exist" means the parts ARE pages, and a page has front matter.
#
# These fixtures are real pages. That is the whole point of the file.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";

my $src = do {
    open my $fh, '<', "$FindBin::Bin/../../../plugins/pandoc.pl" or die $!;
    local $/; <$fh>;
};

subtest 'a part is staged with its front matter removed' => sub {
    my ($block) = $src =~ /(SM738: THE PARTS CONTRIBUTE A BODY.*?my \@cmd = )/s;
    ok( $block, 'the staging block is present' ) or return;

    like( $block, qr/\@inputs = \(\s*\$source_abs\[0\]\s*\)/,
        'the PRIMARY is passed unchanged - its front matter carries title, brand and the parts list' );
    like( $block, qr{s/\\A---\\s\*\\n\.\*\?\\n---\\s\*\\n//s},
        'and each part has a HEAD front-matter block removed' );
    like( $block, qr/\$work\/part-/,
        'into the scratch directory, so the content tree is untouched' );
};

subtest 'the strip takes the head block and leaves a horizontal rule' => sub {
    # The rule that matters: --- at the head is front matter; --- further down
    # is a horizontal rule and belongs to the document.
    my $page = "---\ntitle: Part C\nbrand: plain\n---\n\n# Part C\n\nBody.\n";
    ( my $stripped = $page ) =~ s/\A---\s*\n.*?\n---\s*\n//s;
    unlike( $stripped, qr/^---/m, 'the head block is gone' );
    like( $stripped, qr/# Part C/, 'and the body survives' );

    my $ruled = "# A page\n\nText.\n\n---\n\nMore text.\n";
    ( my $kept = $ruled ) =~ s/\A---\s*\n.*?\n---\s*\n//s;
    like( $kept, qr/^---$/m, 'a rule further down is NOT treated as front matter' );
};

subtest 'a part is resolved before the reader is asked about it' => sub {
    my ($block) = $src =~ /(SM738: RESOLVE FIRST.*?push \@source_abs)/s;
    ok( $block, 'the resolve block is present' ) or return;

    my $resolve_at = index( $src, 'SM738: RESOLVE FIRST' );
    my $mayread_at = index( $src, 'REFUSED, NOT OMITTED' );
    cmp_ok( $resolve_at, '<', $mayread_at,
        'existence is settled BEFORE may_read - otherwise the refusal never fires' );

    like( $block, qr/ref \$o\{resolve\} eq 'CODE'/,
        'the caller may say where a file lives' );
    like( $block, qr/-f "\$docroot\/\$prel" \? "\$docroot\/\$prel" : undef/,
        'and without one the public path is the answer, for a standalone run' );
};

subtest 'the converter failure says nothing about the host at all' => sub {
    # SM739 replaced SM738's sanitising with fixed text. The field pass found
    # what a denylist over somebody else's output will always find: the date
    # came back, inside an echoed command line this time, along with the pandoc
    # invocation and a mojibake byte of stderr. A filter is only ever as good as
    # the last thing that got past it.
    #
    # So this asserts the stronger property - nothing from the converter is
    # interpolated at all - rather than that a particular leak was patched.
    like( $src, qr/the document could not be produced/,
        'the failure is a fixed sentence' );
    like( $src, qr/log_event\(\s*'WARN',[^)]*'pdf conversion failed'/s,
        'and the converter output goes to the log, where it belongs' );

    my ($block) = $src =~ /(the document could not be produced.{0,200})/s;
    unlike( $block, qr/\$why/,
        'the caller-facing message interpolates none of the converter output' );
};

subtest 'the caller supplies the resolver' => sub {
    my $api = do {
        open my $fh, '<', "$FindBin::Bin/../../../lazysite-manager-api.pl" or die $!;
        local $/; <$fh>;
    };
    like( $api, qr/resolve => sub \{/, 'page-pdf passes a resolver' );
    like( $api, qr/Lazysite::Private::resolve\(\s*\$DOCROOT/,
        'which consults the private store - where a read ACL puts content' );
    like( $api, qr/require Lazysite::Private;/,
        'and declares that dependency rather than inheriting it transitively' );
};

done_testing();
