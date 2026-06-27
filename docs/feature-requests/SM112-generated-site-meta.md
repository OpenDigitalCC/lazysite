---
title: "SM112 - lazysite meta tags on generated pages"
subtitle: "Identify the generator (and optional author) in page head"
brand: plain
---

## What

Generated pages should carry standard identifying meta in <head>:

- `<meta name="generator" content="lazysite X.Y.Z">` - the recognised way a CMS marks
  its output (version from the installed release).
- Optional `<meta name="author" content="...">` when the page or site front matter
  provides an author.
- Consider other useful fields where data exists: `description` (from front-matter
  subtitle/summary), `og:title` / `og:description` for link previews, `theme-color`.

## Why

Raised 2026-06-27. A generator tag is conventional and useful (analytics, provenance,
"what built this"); author/description improve sharing and SEO.

## Shape

- Emit `generator` unconditionally from the processor's layout head (the version is
  already known). Gate author/description/OG on available front-matter so nothing
  empty is emitted.
- Make it overridable/disable-able via site config for operators who prefer not to
  advertise the generator.

## Status

**SHIPPED in v0.4.34.** (see CHANGELOG)


Queued. Small: add the meta to the layout head emission in the processor / base
layout, reading the version and front matter already in hand.
