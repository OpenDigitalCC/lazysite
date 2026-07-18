#!/usr/bin/perl
# SM179 P2: language SETS. Two (or more) hosts sharing a `lang_group` are peers -
# each is one language of the same site. The engine exposes [% languages %] (the
# set, with the current one flagged and each sibling's per-path URL) so a layout
# renders a switcher, and emits <link rel="alternate" hreflang> alternates. A
# sibling whose counterpart page does not exist is marked exists=0 and omitted
# from both the switcher and the hreflang set (no links to missing translations).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor);

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite", "$d/sites/en", "$d/sites/de" );

# A language set: the primary is English (rooted at sites/en); a `de.example`
# alias is German (rooted at sites/de). Both carry lang_group `providers`.
open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
print $c <<'CONF';
site_name: T
lang: en
lang_group: providers
site_url: https://en.example
content_root: sites/en
alias_hosts: de.example
alias.de.example.lang: de
alias.de.example.lang_group: providers
alias.de.example.site_url: https://de.example
alias.de.example.content_root: sites/de
CONF
close $c;

# /compare exists in BOTH languages; /only-en exists only in English.
for my $f (qw(index compare)) {
    open my $e, '>', "$d/sites/en/$f.md" or die $!;
    print $e "---\ntitle: $f EN\n---\n\nEN $f\n";
    close $e;
    open my $g, '>', "$d/sites/de/$f.md" or die $!;
    print $g "---\ntitle: $f DE\n---\n\nDE $f\n";
    close $g;
}
open my $o, '>', "$d/sites/en/only-en.md" or die $!;
print $o "---\ntitle: only EN\n---\n\nuntranslated\n";
close $o;

# --- the English (primary) view of a fully translated page --------------------
my $en = run_processor( $d, '/compare', HTTP_HOST => 'en.example' );
like( $en, qr{<strong lang="en">en</strong>},
    'switcher marks the current (en) language, not a link' );
like( $en, qr{<a href="https://de\.example/compare"[^>]*>de</a>},
    'switcher links to the de sibling at the same path' );
like( $en, qr{<link rel="alternate" hreflang="en" href="https://en\.example/compare">},
    'hreflang alternate for en' );
like( $en, qr{<link rel="alternate" hreflang="de" href="https://de\.example/compare">},
    'hreflang alternate for de' );
like( $en, qr{hreflang="x-default"}, 'an x-default alternate is emitted' );

# --- the German view of the same page: de is now current ----------------------
my $de = run_processor( $d, '/compare', HTTP_HOST => 'de.example' );
like( $de, qr{<strong lang="de">de</strong>}, 'the de host marks de as current' );
like( $de, qr{<a href="https://en\.example/compare"[^>]*>en</a>},
    'the de host links back to the en sibling' );

# --- an untranslated page omits the missing sibling ---------------------------
my $only = run_processor( $d, '/only-en', HTTP_HOST => 'en.example' );
unlike( $only, qr{de\.example/only-en},
    'a page with no de counterpart does not link to a missing translation' );
like( $only, qr{<strong lang="en">en</strong>},
    'the current language still shows on an untranslated page' );

# --- a site with no lang_group has no switcher and no alternates --------------
my $p = tempdir( CLEANUP => 1 );
make_path("$p/lazysite");
open my $pc, '>', "$p/lazysite/lazysite.conf" or die $!;
print $pc "site_name: Solo\nlang: en\n";
close $pc;
open my $pi, '>', "$p/index.md" or die $!;
print $pi "---\ntitle: Home\n---\n\nsolo\n";
close $pi;
my $solo = run_processor( $p, '/' );
unlike( $solo, qr{lang-switcher},           'no lang_group => no switcher' );
unlike( $solo, qr{rel="alternate" hreflang}, 'no lang_group => no hreflang alternates' );

done_testing;
