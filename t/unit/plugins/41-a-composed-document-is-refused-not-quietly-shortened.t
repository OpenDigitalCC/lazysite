#!/usr/bin/perl
# SM706: a document assembled from parts, and the PDF kept between requests.
#
# Two things arrive together because they are the same decision seen twice:
# what counts as an INPUT to this document.
#
#   the parts   - a document may name other Markdown files. Each is checked
#                 exactly as the document itself is (inside the docroot,
#                 Markdown, present), and - the release manager's ruling on
#                 MR-67 - a part the reader may not read REFUSES the document
#                 rather than dropping the part. A silently shortened report
#                 looks complete and is not.
#
#   the cache   - the PDF is kept and reused while it post-dates every input.
#                 The brand folder is one of those inputs: a letterhead or
#                 template can change while no page does, and a cache that
#                 watches only the pages serves the old letterhead forever.
#
# Dates, not checksums: hashing every part costs a read of everything the
# render would read. The known cost is a restored back-dated file, which needs
# a rebuild by hand - accepted, and written down here so the next person does
# not "fix" it into a checksum without knowing what they are buying.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;

my $plug = "$FindBin::Bin/../../../plugins/pandoc.pl";
plan skip_all => "no $plug" unless -f $plug;
require $plug;

sub site {
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/lazysite/cache", "$d/lazysite/brands/house", "$d/docs" );
    _w( "$d/docs/part-a.md", "# Summary\n\nThe first part.\n" );
    _w( "$d/docs/part-b.md", "# Accounts\n\nThe second part.\n" );
    _w( "$d/docs/report.md",
              "---\ntitle: Annual Report\nbrand: plain\n"
            . "parts:\n  - docs/part-a.md\n  - docs/part-b.md\n---\n\n"
            . "# Report\n\nThe lead.\n" );
    return $d;
}
sub _w { open my $f, '>', $_[0] or die $!; print {$f} $_[1]; close $f }

subtest 'the parts are read from the front matter' => sub {
    my $d = site();
    is_deeply( main::_parts_of( $d, 'docs/report.md' ),
        [ 'docs/part-a.md', 'docs/part-b.md' ],
        'a parts: list is a list of paths, in the order given' )
        or diag( 'Order is the document order. A composed report whose sections '
            . 'arrive in hash order is a different document each render.' );

    _w( "$d/docs/plain.md", "---\ntitle: Plain\n---\n\n# No parts\n" );
    is_deeply( main::_parts_of( $d, 'docs/plain.md' ), [],
        'a document with no parts: has none' );
};

subtest 'a part the reader may not read REFUSES the document' => sub {
    my $d = site();
    my $r = main::convert(
        docroot  => $d,
        path     => 'docs/report.md',
        may_read => sub { $_[0] ne 'docs/part-b.md' },
    );
    ok( !$r->{ok}, 'the conversion is refused' )
        or diag( 'MR-67, decided by the release manager: refuse. Building '
            . 'without the part hands back a document that reads as whole.' );
    like( $r->{error}, qr/part-b\.md/, 'and the refusal NAMES the part' )
        or diag( 'The person who sees this refusal is not the person who '
            . 'tightened the rule on that file. Without the name they have '
            . 'nothing to take to whoever can fix it.' );

    my $ok = main::convert(
        docroot  => $d,
        path     => 'docs/report.md',
        may_read => sub {1},
    );
    ok( $ok->{ok}, 'while a reader who may read them all gets the document' )
        or diag( $ok->{error} // '' );
} if main::_converter_path();

subtest 'a part is checked exactly as the document is' => sub {
    my $d = site();
    # A REAL .md, outside the docroot. Without this case the traversal guard
    # is never proved: '../../etc/passwd' is refused by the extension check
    # whatever the traversal guard does. Test 40 learned this the hard way for
    # the document path; a part is a second way in and needs the same case.
    make_path("$d/docs/lazysite/cache");
    _w( "$d/escaped.md",     "# Not yours\n" );
    # This one EXISTS, so only the Markdown check can refuse it. Left absent,
    # the existence check refuses it and the extension rule is never proved -
    # a sabotage removing it survived until this file was here.
    _w( "$d/docs/part-a.txt", "not markdown\n" );

    for my $bad ( '../../etc/passwd', '/etc/passwd', 'docs/part-a.txt',
        'docs/missing.md' ) {
        _w( "$d/docs/report.md",
                  "---\ntitle: Annual Report\nbrand: plain\n"
                . "parts:\n  - $bad\n---\n\n# Report\n" );
        my $r = main::convert( docroot => $d, path => 'docs/report.md' );
        ok( !$r->{ok}, "a part is refused: $bad" )
            or diag( 'A part names a file to open. Every guard the document '
                . 'path gets, a part needs, or the parts list is the way '
                . 'around them.' );
    }

    # docroot is docs/; the part is a convertible .md one level above it, so
    # only the traversal guard can refuse it.
    _w( "$d/docs/report.md",
              "---\ntitle: Annual Report\nbrand: plain\n"
            . "parts:\n  - ../escaped.md\n---\n\n# Report\n" );
    my $esc = main::convert( docroot => "$d/docs", path => 'report.md' );
    ok( !$esc->{ok}, 'a part outside the docroot is refused' )
        or diag( 'The extension check passes, the file exists and converts. '
            . 'The traversal guard is the only thing standing here - and a '
            . 'parts list that escapes the docroot reads any file the CGI '
            . 'can, one include at a time.' );
};

subtest 'the PDF is kept, and rebuilt when any input is newer' => sub {
    plan skip_all => 'no md-to-pdf on this host' unless main::_converter_path();
    my $d = site();

    my $first = main::convert( docroot => $d, path => 'docs/report.md' );
    ok( $first->{ok}, 'the document converts' ) or diag( $first->{error} // '' );
    is( $first->{cached}, 0, 'the first render is a render' );
    cmp_ok( $first->{bytes} || 0, '>', 1000, 'and produces a real document' );

    my $again = main::convert( docroot => $d, path => 'docs/report.md' );
    is( $again->{cached}, 1, 'an unchanged document is served from the cache' )
        or diag( 'This render costs a pandoc and a XeLaTeX run inside the '
            . 'request. Repeating it for an unchanged document is the whole '
            . 'reason the cache exists.' );
    is( $again->{pdf}, $first->{pdf}, 'and it is the same file' );

    sleep 1;
    utime undef, undef, "$d/docs/part-b.md";
    is( main::convert( docroot => $d, path => 'docs/report.md' )->{cached},
        0, 'a changed PART invalidates the cache' )
        or diag( 'The document itself did not change. If only its own mtime '
            . 'is watched, editing a section never reaches the reader.' );

    sleep 1;
    _w( "$d/lazysite/brands/house/logo.txt", 'x' );
    utime undef, undef, "$d/lazysite/brands";
    is( main::convert( docroot => $d, path => 'docs/report.md' )->{cached},
        0, 'a changed BRAND invalidates the cache' )
        or diag( 'The letterhead is an input. An operator who changes the '
            . 'logo and sees the old one on every existing document has a '
            . 'cache they cannot reason about.' );

    ok( -f "$d/lazysite/cache/pdf/docs_report.md.pdf",
        'and the cache lives under lazysite/, which is not served' )
        or diag( 'A rendered PDF in the document root answers an anonymous '
            . 'GET - the same mistake SM694 fixed for the brand folder.' );
};

subtest 'and what fills the cache can empty it' => sub {
    my $d = site();
    my $empty = main::plugin_clear($d);
    ok( $empty->{ok}, 'clearing an empty cache is not an error' );
    is( $empty->{cleared}, 0, 'and it says nothing was there' )
        or diag( 'An operator who clears twice should be told the second '
            . 'did nothing, rather than shown the same "done" both times.' );

    make_path("$d/lazysite/cache/pdf");
    # TWO, so the count is a count. With one file a hardcoded 1 passes, and a
    # sabotage returning a fixed count survived until this was here.
    _w( "$d/lazysite/cache/pdf/docs_report.md.pdf", 'not really a pdf' );
    _w( "$d/lazysite/cache/pdf/docs_other.md.pdf",  'nor this' );
    _w( "$d/lazysite/cache/pdf/keep.txt",           'not a pdf at all' );
    my $r = main::plugin_clear($d);
    is( $r->{cleared}, 2, 'the cached PDFs are cleared, and counted' )
        or diag( 'SM706 required the cache be sweepable: a stale PDF nothing '
            . 'can clear is worse than a slow one. The rendered-page sweep '
            . 'does not touch this folder - it clears lazysite/cache/hosts.' );
    ok( !-e "$d/lazysite/cache/pdf/docs_report.md.pdf", 'the file is gone' );
    ok( -e "$d/lazysite/cache/pdf/keep.txt",
        'and nothing else in the folder is touched' )
        or diag( 'This runs as the CGI inside the site. A sweep that deletes '
            . 'by folder rather than by what it wrote is a delete primitive.' );

    my $act = main::describe()->{actions};
    ok( ( grep { $_->{id} eq 'clear' } @$act ),
        'and the operator can reach it from the Plugin Manager' )
        or diag( 'A sweep with no button is a sweep nobody performs.' );
};

done_testing();
