#!/usr/bin/perl
# SM179 P5: a layout localises its chrome via layouts/<layout>/strings/<lang>.json.
# The engine loads [% t %] = strings/en.json (the English base) overlaid by the
# site language's file, so [% t.footer_credit %] renders the site language and any
# key missing from that language falls back to English rather than vanishing.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor);

my $d = tempdir( CLEANUP => 1 );
make_path(
    "$d/lazysite/layouts/loc/strings",
    "$d/sites/de",
);

# A minimal local layout that prints two chrome strings from [% t %].
open my $l, '>', "$d/lazysite/layouts/loc/layout.tt" or die $!;
print $l qq{<!doctype html><html lang="[% page_lang %]"><body>\n}
    . qq{<p id="foot">[% t.footer_credit %]</p>\n}
    . qq{<p id="more">[% t.more %]</p>\n}
    . qq{[% content %]</body></html>\n};
close $l;

# English base: both keys. German: overrides footer_credit only (more falls back).
open my $en, '>', "$d/lazysite/layouts/loc/strings/en.json" or die $!;
print $en '{"footer_credit":"Built with Lazysite","more":"Read more"}';
close $en;
open my $de, '>', "$d/lazysite/layouts/loc/strings/de.json" or die $!;
print $de '{"footer_credit":"Erstellt mit Lazysite"}';
close $de;

open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
print $c <<'CONF';
site_name: T
layout: loc
lang: en
alias_hosts: de.example
alias.de.example.lang: de
alias.de.example.content_root: sites/de
CONF
close $c;

open my $ei, '>', "$d/index.md" or die $!;
print $ei "---\ntitle: Home\n---\n\nEN home\n";
close $ei;
open my $di, '>', "$d/sites/de/index.md" or die $!;
print $di "---\ntitle: Heim\n---\n\nDE home\n";
close $di;

# --- English host: base strings -----------------------------------------------
my $en_out = run_processor( $d, '/', HTTP_HOST => 'en.example' );
like( $en_out, qr{<p id="foot">Built with Lazysite</p>}, 'en uses the English string' );
like( $en_out, qr{<p id="more">Read more</p>},           'en shows the English "more"' );

# --- German host: overridden string, fallback for the missing key -------------
my $de_out = run_processor( $d, '/', HTTP_HOST => 'de.example' );
like( $de_out, qr{<p id="foot">Erstellt mit Lazysite</p>},
    'de uses the German override for footer_credit' );
like( $de_out, qr{<p id="more">Read more</p>},
    'a key absent from de falls back to the English base' );

# --- a layout with no strings/ dir is unaffected (t is an empty hash) ----------
my $p = tempdir( CLEANUP => 1 );
make_path("$p/lazysite/layouts/bare");
open my $bl, '>', "$p/lazysite/layouts/bare/layout.tt" or die $!;
print $bl qq{<html><body><p id="foot">[[[% t.footer_credit %]]]</p>[% content %]</body></html>\n};
close $bl;
open my $pc, '>', "$p/lazysite/lazysite.conf" or die $!;
print $pc "site_name: T\nlayout: bare\n";
close $pc;
open my $pi, '>', "$p/index.md" or die $!;
print $pi "---\ntitle: H\n---\n\nx\n";
close $pi;
my $bare = run_processor( $p, '/' );
like( $bare, qr{\Q[[]]\E}, 'no strings/ dir => [% t.x %] renders empty, no error' );

done_testing;
