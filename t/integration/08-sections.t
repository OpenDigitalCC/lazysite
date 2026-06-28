#!/usr/bin/perl
# D035 Phase 3: front-matter `sections:` (data-driven pages). The minimal nested
# YAML parser turns a sequence of single-key maps into `sections`, which the
# layout dispatches to components/<type>.tt as `data`. Exercises nested maps,
# nested sequences, inline flow maps, and the markdown filter on a data field.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor);

my $docroot = tempdir( CLEANUP => 1 );
my $cdir    = "$docroot/lazysite/layouts/nova/components";
make_path($cdir);

open my $lf, '>', "$docroot/lazysite/layouts/nova/layout.tt" or die $!;
print $lf <<'TT';
<!DOCTYPE html><html><head><title>[% page_title %]</title></head><body>
[% FOREACH s IN sections %][% type = s.keys.first %][% INCLUDE "components/${type}.tt" data = s.$type %]
[% END %]<main>[% content %]</main>
</body></html>
TT
close $lf;

open my $hero, '>', "$cdir/hero.tt" or die $!;
print $hero <<'TT';
<section class="hero">
[% IF data.eyebrow %]<span class="eyebrow">[% data.eyebrow %]</span>[% END %]
<h1>[% data.heading | markdown %]</h1>
[% IF data.actions %]<ul class="cta">[% FOREACH a IN data.actions %]<li><a href="[% a.href %]" class="[% a.style %]">[% a.label %]</a></li>[% END %]</ul>[% END %]
</section>
TT
close $hero;

open my $grid, '>', "$cdir/feature-grid.tt" or die $!;
print $grid <<'TT';
<div class="grid">[% FOREACH it IN data.items %]<div class="cell"><h3>[% it.title %]</h3><p>[% it.body %]</p></div>[% END %]</div>
TT
close $grid;

open my $conf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print $conf "site_name: Test\nlayout: nova\n";
close $conf;

open my $nf, '>', "$docroot/404.md" or die $!;
print $nf "---\ntitle: NF\n---\nNot found.\n";
close $nf;

open my $pg, '>', "$docroot/nova.md" or die $!;
print $pg <<'MD';
---
title: NOVA
sections:
  - hero:
      eyebrow: Generative
      heading: "A site that's *alive*."
      lead: The field behind these words is drawn live
      actions:
        - { label: How it works, href: '#concept', style: primary }
        - { label: Get started,  href: '#start' }
  - feature-grid:
      items:
        - { icon: spark, title: No framework, body: "Native CSS and a little JS." }
        - { icon: bolt,  title: Instant,      body: "No build, no database." }
---
Body text.
MD
close $pg;

my $out = run_processor( $docroot, '/nova' );

like( $out, qr{<section class="hero">}, 'hero section dispatched from sections' );
like( $out, qr{<span class="eyebrow">Generative</span>}, 'nested map scalar (eyebrow)' );
like( $out, qr{<h1>A site that's <em>alive</em>\.</h1>}, 'markdown filter on a data field' );
like( $out, qr{href="#concept" class="primary">How it works</a>},
    'nested sequence of inline flow maps (first action)' );
like( $out, qr{href="#start"[^>]*>Get started</a>}, 'second action' );
like( $out, qr{<div class="grid">}, 'feature-grid section dispatched' );
like( $out, qr{<h3>No framework</h3><p>Native CSS and a little JS\.</p>},
    'feature-grid item 1 (flow map fields)' );
like( $out, qr{<h3>Instant</h3><p>No build, no database\.</p>}, 'feature-grid item 2' );
like( $out, qr{Body text\.}, 'Markdown body still renders below the sections' );

# Flow-style YAML must parse too (regression: a slurp bug made a 2-item flow
# list report 5 items). feature-grid items here are an inline flow sequence.
open my $fp, '>', "$docroot/flow.md" or die $!;
print $fp <<'MD';
---
title: Flow
sections:
  - feature-grid:
      items: [{title: One, body: First}, {title: Two, body: Second}]
---
MD
close $fp;
my $fout = run_processor( $docroot, '/flow' );
like( $fout, qr{<h3>One</h3><p>First</p>}, 'flow-style: item 1 parsed' );
like( $fout, qr{<h3>Two</h3><p>Second</p>}, 'flow-style: item 2 parsed (not 5)' );

done_testing;
