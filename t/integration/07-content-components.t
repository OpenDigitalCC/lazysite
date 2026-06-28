#!/usr/bin/perl
# D035 content components.
# Phase 1: the layout TT engine resolves [% INCLUDE 'components/NAME.tt' %]
# against the active layout's directory, and a `markdown` filter renders Markdown
# fields (inline single-paragraph values unwrapped; usable inside a component).
# Phase 2: a ::: <name> fence whose name matches components/<name>.tt is rendered
# THROUGH that component - inner Markdown -> content, key="value" -> attrs, nested
# ::: <slot> fences -> slots.<slot>.
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
[% INCLUDE 'components/card.tt' heading = 'Hello' %]
<p class="inline">[% "loud and *clear*" | markdown %]</p>
[% INCLUDE 'components/lead.tt' text = 'via *component*' %]
<main>[% content %]</main>
</body></html>
TT
close $lf;

open my $cf, '>', "$cdir/card.tt" or die $!;
print $cf qq{<section class="card"><h2>[% heading %]</h2></section>\n};
close $cf;

open my $lcf, '>', "$cdir/lead.tt" or die $!;
print $lcf qq{<p class="lead">[% text | markdown %]</p>\n};
close $lcf;

# Phase 2 component: hero with an eyebrow attr, content, and an actions slot.
open my $hf, '>', "$cdir/hero.tt" or die $!;
print $hf <<'TT';
<section class="hero">
[% IF attrs.eyebrow %]<span class="eyebrow">[% attrs.eyebrow %]</span>[% END %]
[% content %]
[% IF slots.actions %]<div class="cta">[% slots.actions %]</div>[% END %]
</section>
TT
close $hf;

open my $conf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print $conf "site_name: Test\nlayout: nova\n";
close $conf;

open my $idx, '>', "$docroot/index.md" or die $!;
print $idx "---\ntitle: Home\n---\nBody copy.\n";
close $idx;

# Page authored in Markdown using the hero component.
open my $hp, '>', "$docroot/launch.md" or die $!;
print $hp <<'MD';
---
title: Launch
---
::: hero eyebrow="Generative"
# A site that's *alive*.

Field text here.

::: actions
[Go now](#start)
:::
:::

Tail paragraph.
MD
close $hp;

open my $nf, '>', "$docroot/404.md" or die $!;
print $nf "---\ntitle: NF\n---\nNot found.\n";
close $nf;

# --- Phase 1 ---
my $home = run_processor( $docroot, '/' );
like( $home, qr{<section class="card"><h2>Hello</h2></section>},
    'P1: component INCLUDE resolves against the layout directory' );
like( $home, qr{loud and <em>clear</em>}, 'P1: markdown filter renders inline' );
unlike( $home, qr{<p class="inline"><p>}, 'P1: inline markdown not double-<p>-wrapped' );
like( $home, qr{<p class="lead">via <em>component</em></p>},
    'P1: markdown filter available inside a component' );

# --- Phase 2 ---
my $out = run_processor( $docroot, '/launch' );
like( $out, qr{<section class="hero">}, 'P2: hero component scaffolding emitted' );
like( $out, qr{<span class="eyebrow">Generative</span>}, 'P2: attrs parsed from opening line' );
like( $out, qr{A site that's <em>alive</em>}, 'P2: inner Markdown rendered as content' );
like( $out, qr{<div class="cta">.*href="#start".*Go now}s, 'P2: nested actions slot rendered' );
like( $out, qr{Tail paragraph\.}, 'P2: text after the component still renders' );
unlike( $out, qr{^:::}m, 'P2: no raw ::: fences leak into output' );

done_testing;
