#!/usr/bin/perl
# SM179 P8: engine-emitted chrome is localised off the host language, with an
# English fallback, and the bare 404 fallback HTML-escapes the request URI (it
# was interpolated raw before). Covers the built-in 404 path; the auth reject
# pages route the same strings through the same Lazysite::I18n helper.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor);

# A site with NO 404.md, so the engine's bare fallback is what renders.
sub site {
    my (%o) = @_;
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite");
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $c ( $o{conf} // "site_name: T\n" );
    close $c;
    open my $i, '>', "$d/index.md" or die $!;
    print $i "---\ntitle: Home\n---\n\nhi\n";
    close $i;
    if ( $o{i18n} ) {
        make_path("$d/lazysite/i18n");
        open my $j, '>', "$d/lazysite/i18n/$o{i18n}{lang}.json" or die $!;
        print $j $o{i18n}{json};
        close $j;
    }
    return $d;
}

# --- English site: bare 404 fallback, English -----------------------------------
my $out = run_processor( site(), '/no-such-page' );
like( $out, qr/Status:\s*404/i,          '404 status' );
like( $out, qr/Page not found:/,          'English fallback text' );

# --- the request URI is HTML-escaped (was raw - a reflected-markup vector) -----
$out = run_processor( site(), '/x"><b>oops' );
unlike( $out, qr/<b>oops/,    'raw markup from the URI is NOT reflected' );
like( $out, qr/&lt;b&gt;oops/, 'the URI is HTML-escaped in the 404 body' );

# --- a German site with an i18n override: localised fallback ------------------
$out = run_processor(
    site( conf => "site_name: T\nlang: de\n",
        i18n => { lang => 'de', json => '{"notfound.body":"Seite nicht gefunden: %s"}' } ),
    '/weg'
);
like( $out, qr/Seite nicht gefunden:/, 'de override localises the 404 body' );

# --- a German site with NO override file: English fallback (fail-closed) -------
$out = run_processor( site( conf => "site_name: T\nlang: de\n" ), '/weg' );
like( $out, qr/Page not found:/, 'lang set but no override => English fallback' );

done_testing;
