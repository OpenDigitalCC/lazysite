#!/usr/bin/perl
# SM179 P4: a json: source resolves against the request's CONTENT ROOT first, then
# the docroot (shared data). So a page's `json:/data/x.json` reads its OWN root's
# data on a per-language/per-domain root - portable across roots - and falls back
# to a shared docroot file when the root has none. (The wart: without this every
# translated page needed a docroot-absolute path into its own root.)
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor);

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite", "$d/data", "$d/sites/de/data" );

open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
print $c "site_name: T\nalias_hosts: de.example\nalias.de.example.content_root: sites/de\n";
close $c;

# Same relative path in both roots, distinct content; plus a docroot-only shared file.
open my $j1, '>', "$d/data/x.json" or die $!; print $j1 '{"who":"DOCROOT"}'; close $j1;
open my $j2, '>', "$d/sites/de/data/x.json" or die $!; print $j2 '{"who":"CROOT-DE"}'; close $j2;
open my $j3, '>', "$d/data/shared.json" or die $!; print $j3 '{"who":"SHARED"}'; close $j3;

# The DE root's page references both by content-root-relative path.
open my $p, '>', "$d/sites/de/page.md" or die $!;
print $p <<'MD';
---
title: P
tt_page_var:
  local: json:/data/x.json
  shared: json:/data/shared.json
---
LOCAL=[% local.who %] SHARED=[% shared.who %]
MD
close $p;

# The primary (docroot) also has a page referencing the same path.
open my $pp, '>', "$d/root.md" or die $!;
print $pp "---\ntitle: R\ntt_page_var:\n  local: json:/data/x.json\n---\nROOT=[% local.who %]\n";
close $pp;

# --- the DE root reads its OWN data (croot-first) --------------------------
my $de = run_processor( $d, '/page', HTTP_HOST => 'de.example' );
like( $de, qr/LOCAL=CROOT-DE/, 'json: resolves against the content root first' );
like( $de, qr/SHARED=SHARED/,  'json: falls back to the docroot for a shared file' );

# --- the primary host reads the docroot copy ------------------------------
my $root = run_processor( $d, '/root', HTTP_HOST => 'primary.example' );
like( $root, qr/ROOT=DOCROOT/, 'the primary host reads the docroot json' );

done_testing;
