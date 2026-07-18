package Lazysite::I18n;

# SM179 P8: localisation of engine-EMITTED chrome - the handful of strings the
# engine prints itself (the bare 404 fallback, "Authentication required", the
# auth reject pages), as opposed to authored .md pages (login/404/403), which a
# language set already translates as ordinary content.
#
# A built-in English table is the source of truth AND the guaranteed fallback; a
# site supplies translations in lazysite/i18n/<lang>.json (a flat
# key -> string map), overlaid per key. Keyed off the site language (site_lang).
#
# HARD SAFETY LINE: fail-closed to English. Any miss - unknown language, missing
# key, unreadable/invalid JSON, an empty translation - yields the English string.
# The language never affects an auth DECISION, only display text, and a mis-set
# language must never blank a page or hide why sign-in failed. Interpolated
# arguments are HTML-escaped (callers emit into HTML); the table text is trusted.

use strict;
use warnings;
use JSON::PP ();
use Exporter 'import';
our @EXPORT_OK = qw(chrome_string);

my %EN = (
    'notfound.body'          => 'Page not found: %s',
    'forbidden.title'        => 'Access Denied',
    'forbidden.insufficient' => 'You do not have permission to view this page.',
    'auth.required'          => 'Authentication required.',
    'signin.title'           => 'Sign in',
    'auth.nopw.title'        => 'Sign in unavailable',
    'auth.nopw.body'         => 'Password not configured - contact your administrator.',
    'auth.uidisabled.title'  => 'Interactive login is disabled for this account',
    'auth.uidisabled.body'   =>
        'This account does not have interactive (browser) access. '
        . 'If it is used for publishing, connect over WebDAV instead.',
);

# Per-language override file, memoised per (docroot, lang). A lang code is
# validated before it can name a file (no traversal); a bad/absent file is {}.
my %CACHE;

sub _overlay {
    my ( $docroot, $lang ) = @_;
    return {} unless defined $lang && $lang =~ /^[A-Za-z][A-Za-z-]*$/;
    my $key = ( $docroot // '' ) . "\0" . lc $lang;
    return $CACHE{$key} if exists $CACHE{$key};

    my $path = ( $docroot // '' ) . "/lazysite/i18n/" . lc($lang) . ".json";
    my $data = {};
    if ( open my $fh, '<:raw', $path ) {
        local $/;
        my $raw = <$fh>;
        close $fh;
        my $decoded = eval { JSON::PP::decode_json($raw) };
        $data = $decoded if ref $decoded eq 'HASH';
    }
    $CACHE{$key} = $data;
    return $data;
}

# chrome_string($docroot, $lang, $key, @args) -> the localised string.
# English base, overlaid by lazysite/i18n/<lang>.json when $lang is non-English
# and the file supplies a non-empty value for $key. %s placeholders are filled
# from @args, each HTML-escaped. An unknown key returns the key itself (never
# blank), so a typo is visible rather than silently empty.
sub chrome_string {
    my ( $docroot, $lang, $key, @args ) = @_;
    my $s = defined $EN{$key} ? $EN{$key} : $key;

    if ( defined $lang && length $lang && lc $lang ne 'en' ) {
        my $ov = _overlay( $docroot, $lang );
        $s = $ov->{$key}
            if ref $ov eq 'HASH' && defined $ov->{$key} && length $ov->{$key};
    }

    if (@args) {
        $s = sprintf( $s, map { _esc($_) } @args );
    }
    return $s;
}

sub _esc {
    my ($v) = @_;
    $v = '' unless defined $v;
    $v =~ s/&/&amp;/g;
    $v =~ s/</&lt;/g;
    $v =~ s/>/&gt;/g;
    $v =~ s/"/&quot;/g;
    return $v;
}

# Test seam: drop the memo so a test can rewrite an override file and re-read.
sub _reset_cache { %CACHE = (); return }

1;
