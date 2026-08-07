---
title: "SM236 - Stock layouts declare no icon link"
subtitle: "Sites on bespoke layouts have a favicon link because someone hand-authored one. Sites on stock layouts have none, and rely on browsers guessing by convention."
brand: plain
status: candidate
status-note: "Reported by the sjm-claude-code site agent 2026-08-07 alongside SM235. Cosmetic rather than broken - a root favicon.ico still works by convention. Verified: lazysite core emits no icon link anywhere, and the stock layouts are not in this repository, so the fix likely belongs to the layout catalogue. Recorded here because the decision about WHERE it belongs is a core one."
---

# SM236 - stock layouts declare no icon link

## Why

Sites running bespoke layouts (dito-r6, cloudient7, odyssey-r4) emit
`<link rel="icon">` in the head, because whoever authored the layout put one
there. Sites on stock layouts (sovereigncomputing, lazysite.io, ctrl-exec.io)
emit none.

A root `/favicon.ico` and `/apple-touch-icon.png` are still found by convention,
so nothing is broken. What is lost is control: a site cannot point at a
differently named or differently located icon, cannot declare multiple sizes, and
cannot declare an SVG icon at all. The site-facing consequence is small and the
inconsistency is the real complaint - the same site looks correctly configured or
not depending on which layout it happens to run.

This also sits against a standing operator practice of ensuring every granted
site has a favicon, which currently has to be checked and fixed per site rather
than being right by default.

## What is true today

Verified: nothing in lazysite core emits an icon link. There is no head partial
or default template that a layout inherits - the head is entirely the layout's,
and `starter/lazysite/templates/` holds only registry templates (sitemap, feeds,
llms.txt) and components.

The stock layouts themselves are not in this repository. They come from the
layout catalogue, so the change is not a core code change.

## The decision this needs

Two places it could live, and they are not equivalent.

**In each stock layout.** Add the link to the head of every catalogue layout.
Correct, and it is per-layout work that must be repeated for every future layout
and cannot fix a site until its layout is updated.

**In the engine, as a default the layout may override.** The processor already
resolves per-site variables and could offer an icon link the layout head
includes, defaulting to the conventional root paths when the site declares
nothing. Fixes every site at once, including existing ones, and it puts a piece
of head markup back into the engine that ADR 0001 and the layout separation have
deliberately kept out.

The second is more useful and the more consequential; it should not be taken
casually just because it is convenient. Recommend deciding this explicitly rather
than defaulting to whichever is quicker.

## If it goes in the layouts

- Add `<link rel="icon">` to each stock layout head, resolving a site-declared
  path where one exists and the conventional root path otherwise.
- Make it part of whatever layout-authoring checklist exists, so new layouts do
  not reintroduce the gap.

## If it goes in the engine

- A site variable for the icon path, defaulting to the conventional root file
  when unset and absent when the site sets it empty.
- Emitted only where the layout asks for it, so a layout that wants full control
  of its head keeps it.

## Not in scope

- Generating or converting icon artwork. That is site work.
- Changing how `/favicon.ico` is served.
