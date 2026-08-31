#!/usr/bin/perl
# An asset that ships is an asset the page loads.
#
# SM698 bundled 21 woff2 faces and wrote assets/fonts.css to declare them, so
# the manager would need no external request. Nothing linked it. The manager
# sheets carried a COMMENT saying to load it - an instruction to a reader,
# which no browser reads - so Barlow never arrived and every style fell back to
# the system font stack. `modern` and `accessible` were drawn around that face
# and rendered in something else, which is the kind of fault that looks like a
# design disagreement rather than a missing link tag.
#
# Shipping an asset and referencing it are two different acts, and only the
# second one shows up in a browser.
use strict;
use warnings;
use Test::More;
use FindBin;

my $root   = "$FindBin::Bin/../..";
my $layout = "$root/starter/lazysite/manager/layout.tt";
my $assets = "$root/starter/lazysite/manager/assets";
ok( -f $layout, 'the manager layout is present' ) or BAIL_OUT("no $layout");

my $tt = do { open my $fh, '<', $layout or die $!; local $/; <$fh> };

subtest 'the bundled faces are linked, and the files are there' => sub {
    like( $tt, qr{<link[^>]+href="/manager/assets/fonts\.css},
        'the layout links fonts.css' )
        or diag( 'The sheets name Barlow in --mg-font. Without this link the '
            . '@font-face rules never load and every style silently uses the '
            . 'system font.' );
    ok( -f "$assets/fonts.css", 'fonts.css ships' );
    my @faces = glob "$assets/fonts/*.woff2";
    cmp_ok( scalar @faces, '>', 0, 'the face files ship too' )
        or diag( 'A @font-face pointing at nothing fails silently - the '
            . 'browser falls back and says nothing.' );
};

subtest 'every face fonts.css declares actually exists' => sub {
    my $css = do { open my $fh, '<', "$assets/fonts.css" or die $!; local $/; <$fh> };
    my @missing;
    while ( $css =~ m{url\(['"]?([^'")]+\.woff2)}g ) {
        my $rel = $1;
        $rel =~ s{^\./}{};
        $rel =~ s{^/manager/assets/}{};
        push @missing, $rel unless -f "$assets/$rel";
    }
    is( "@missing", '', 'no @font-face points at a file that is not shipped' )
        or diag( "Missing:\n  " . join( "\n  ", @missing ) );
};

subtest 'the fonts are local, not fetched' => sub {
    my $css = do { open my $fh, '<', "$assets/fonts.css" or die $!; local $/; <$fh> };
    unlike( $css, qr{https?://}, 'fonts.css makes no external request' )
        or diag( 'A manager that fetches its fonts from a third party tells '
            . 'that party an admin panel was opened, from this address, at '
            . 'this time - on every page load.' );
    unlike( $tt, qr{<link[^>]+href="https?://},
        'the layout loads no external stylesheet' );
};

done_testing();
