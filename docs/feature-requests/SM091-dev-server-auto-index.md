---
title: "SM091 - dev-server auto-index: browse any tree with no index files"
subtitle: "Point lazysite-server.pl at an arbitrary folder of Markdown and get a generated index + breadcrumb nav, writing nothing"
brand: plain
---

::: widebox
`tools/lazysite-server.pl` already serves any docroot with caching off and the
built-in fallback layout (no theme needed) - a great way to preview a tree of
Markdown with zero install. Two things stop it being a one-command "browse any
folder": a directory with no `index.md` returns 404 (many trees use `README.md`,
or no index at all), and the server seeds a `lazysite/` dir into the docroot. This
adds `--auto-index`, which generates a directory listing + breadcrumb nav on the
fly (writing nothing), and stops the seeding from touching a non-lazysite tree.
:::

## Motivation

The use case surfaced browsing the `toolchain-development/topics` corpus: "throw up
a lazysite processor with no cache, no theme, just point at a tree". The processor
and dev server already do the hard part; the friction was purely that an arbitrary
documentation tree (folders of `.md`, `README.md` as the index, no `index.md`) is
not directly browsable, and that the server writes scaffolding into the tree.

## What ships

`--auto-index` (off by default; opt-in):

generated directory index
: a GET for a directory with no `index.md` (and no same-named `<dir>.md`) returns a
  generated HTML listing - sub-folders and pages as links, page labels taken from
  each note's front-matter `title`, the directory's `README` linked as an overview
  if present. Self-contained inline CSS, consistent with the fallback layout.

breadcrumb nav
: every page served while `--auto-index` is on gets a small breadcrumb
  (`index / area / page`) injected at the top of `<body>`, so any note links back
  up to its folder index and the root. This is the "dynamic nav, built from the
  content" - no `nav.conf` required, nothing written.

no-pollution seeding
: the auth/forms scaffolding seeding only runs when the docroot is actually a
  lazysite site (has `lazysite/` or a `lazysite.conf.example`). Pointed at an
  arbitrary tree, the server now creates nothing in it.

Writes nothing to the docroot in either case - the index and nav are generated
per request, honouring the no-cache, read-only-browse spirit.

## Non-goals (for this cut)

- Persisting a generated `index.md` / `nav.conf` to disk (deliberately not done -
  the point is a read-only browse; a `--write-index` could be a later opt-in).
- A full sidebar tree on every page (the breadcrumb is the v1 nav; a fuller
  generated sidebar is a follow-on).
- Production use - the dev server remains local-development-only.

## Docs

The "browse any tree of Markdown, no install, no cache, no theme" recipe is
promoted to the top-level `README.md` quick-start, the server's `--help`, and the
dev-server section of `starter/docs/development.md` (`--auto-index` / `--no-seed`,
and the off-docroot cache relocation).

## Status

Implemented 2026-06-26. `--auto-index` in `tools/lazysite-server.pl`; seeding
guarded; README + `docs/dev-server.md` + `--help` updated. Dev-server smoke-tested
(generated root + sub-directory index, breadcrumb on a note, no files written to
the tree).
