#!/usr/bin/perl
# SM179 P8: Lazysite::I18n - localisation of engine-emitted chrome. English base
# + guaranteed fallback, per-site lazysite/i18n/<lang>.json overlay, %s args
# HTML-escaped, and fail-closed on every miss (no lang / unknown key / bad file /
# empty translation / traversal lang code all yield the English string).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::I18n qw(chrome_string);

my $d = tempdir( CLEANUP => 1 );

# --- English base + fallbacks -------------------------------------------------
is( chrome_string( $d, 'en', 'auth.required' ),
    'Authentication required.', 'English string' );
is( chrome_string( $d, undef, 'auth.required' ),
    'Authentication required.', 'no lang => English' );
is( chrome_string( $d, 'de', 'auth.required' ),
    'Authentication required.', 'non-English but no override file => English fallback' );
is( chrome_string( $d, 'en', 'no.such.key' ),
    'no.such.key', 'unknown key => the key itself, never blank' );

# --- %s interpolation is HTML-escaped -----------------------------------------
is( chrome_string( $d, 'en', 'notfound.body', '/a&b<c">' ),
    'Page not found: /a&amp;b&lt;c&quot;&gt;',
    'interpolated arg is HTML-escaped (reflected-markup safe)' );

# --- a per-site override overlays the English base per key --------------------
make_path("$d/lazysite/i18n");
open my $de, '>', "$d/lazysite/i18n/de.json" or die $!;
print $de '{"auth.required":"Anmeldung erforderlich.","auth.nopw.title":""}';
close $de;
Lazysite::I18n::_reset_cache();

is( chrome_string( $d, 'de', 'auth.required' ),
    'Anmeldung erforderlich.', 'de override applied' );
is( chrome_string( $d, 'DE', 'auth.required' ),
    'Anmeldung erforderlich.', 'lang match is case-insensitive' );
is( chrome_string( $d, 'de', 'forbidden.title' ),
    'Access Denied', 'a key absent from the override falls back to English' );
is( chrome_string( $d, 'de', 'auth.nopw.title' ),
    'Sign in unavailable', 'an EMPTY override value falls back to English (never blank)' );

# --- fail-closed: a broken override file yields English -----------------------
open my $fr, '>', "$d/lazysite/i18n/fr.json" or die $!;
print $fr '{ this is not json';
close $fr;
Lazysite::I18n::_reset_cache();
is( chrome_string( $d, 'fr', 'auth.required' ),
    'Authentication required.', 'unparseable override => English fallback' );

# --- a traversal / invalid lang code can never name a file --------------------
is( chrome_string( $d, '../../etc/passwd', 'auth.required' ),
    'Authentication required.', 'invalid lang code => English, no file access' );

done_testing;
