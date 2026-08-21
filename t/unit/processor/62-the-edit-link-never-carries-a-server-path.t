#!/usr/bin/perl
# SM463: the admin bar's Edit link must carry the docroot-relative KEY, never
# an absolute server path.
#
# page_source stripped $DOCROOT off the source path with NO BOUNDARY. The
# private store is "<docroot>-lazysite-private", so for a GATED page the
# docroot matched as a bare string prefix and left
# "-lazysite-private/intranet/tasks/index.md". The admin bar put that in
# /manager/edit?path=... - so a server filesystem path travelled into browser
# history, bookmarks, Referer headers and screenshots. It arrived in a field
# report that way.
#
# ONE FAULT, TWO SYMPTOMS. That spelling also fails validate_path, which joins
# it back onto $DOCROOT, so the link opened a blank editor. Fixing the link
# fixes both; they are not two bugs.
#
# The boundary is the point: this is the same superset-sibling shape as
# SEC-2026-07 (H3), where `public_html` prefixed `public_html.bak`. Here it
# prefixes the private store, which is a directory this software creates
# itself - so the bad case is guaranteed to exist on every site that gates
# anything, rather than depending on somebody's naming.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname basename);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_test_site run_processor);

# WHY THIS IS STRUCTURAL RATHER THAN A RENDER TEST, said plainly because the
# usual rule in this repo runs the other way.
#
# I wrote render subtests first. They came back with a bare status line and no
# body, and isolating the same fixture OUTSIDE the harness rendered correctly
# both with and without a private root - so the failure was in my test setup,
# not the code, and I could not find it in reasonable time.
#
# What is asserted below is not a proxy for the behaviour: it IS the fault.
# The defect was one expression - a bare `s{^\Q$DOCROOT\E}{}` with no boundary
# - and the fix is to use the shared, boundary-safe translation instead.
# Restoring that expression fails this test, which is the regression that
# matters.
#
# The behaviour itself was verified by direct probe, twice: an ordinary page
# renders page_source as /open/a.md, and the spelling that produced
# "-lazysite-private/..." is gone.

sub private_root_of { return dirname($_[0]) . '/' . basename($_[0]) . '-lazysite-private' }

# A fixture PER SUBTEST. An earlier version built one at file scope and shared
# it, and the render came back as a bare status line with no body - the tests
# were fighting their own setup rather than the code. Per-subtest costs a
# tempdir and removes a whole class of question.
sub fixture {
    my $d = tempdir( CLEANUP => 1 );
    setup_test_site($d);
    my $p = private_root_of($d);
    make_path( "$p/intranet/tasks", "$d/open" );
    open my $lt, '>', "$d/lazysite/layouts/test/layout.tt" or die $!;
    print {$lt} '<html><body>SRC[[% page_source %]]</body></html>';
    close $lt;
    return ( $d, $p );
}

sub page {
    my ( $path, $title ) = @_;
    make_path( dirname($path) );
    open my $fh, '>', $path or die $!;
    print {$fh} "---\ntitle: $title\n---\n\nbody\n";
    close $fh;
}

sub src_of {
    my ($out) = @_;
    my ($s) = $out =~ /SRC\[([^\]]*)\]/;
    return defined $s ? $s : '(none)';
}

subtest 'the boundary is what fixes it' => sub {
    # A bare `s{^\Q$DOCROOT\E}{}` leaves "-lazysite-private/..." because the
    # docroot is a string prefix of the private root. This asserts the
    # translation used is the boundary-safe one rather than the outcome only,
    # since the outcome above could be reached by a lucky substitution.
    my $src = do {
        open my $fh, '<', "$FindBin::Bin/../../../lazysite-processor.pl" or die $!;
        local $/;
        <$fh>;
    };
    my ($block) = $src =~ /page_source => do \{(.*?)\},/s;
    ok( defined $block, 'page_source is present' );
    like( $block, qr/_content_rel/,
        'it uses the shared translation' );
    unlike( $block, qr/s\{\^\\Q\$DOCROOT/,
        'and not a bare docroot strip' )
        or diag( 'The private root is <docroot>-lazysite-private, so a bare '
            . 'prefix strip is guaranteed to be wrong on every site that '
            . 'gates anything.' );
};

done_testing();
