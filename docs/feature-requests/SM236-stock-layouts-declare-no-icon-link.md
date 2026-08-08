---
title: "SM236 - Stock layouts declare no icon link"
subtitle: "Sites on bespoke layouts have a favicon link because someone hand-authored one. Sites on stock layouts have none, and rely on browsers guessing by convention."
brand: plain
status: parked
status-note: "DECIDED 2026-08-08 by the operator: the fix belongs in the LAYOUT CATALOGUE, not the engine. Parked here rather than closed - the work is real, it has moved to a repository this one does not contain. The engine alternative (a default icon link every site inherits) was rejected because it puts head markup back into the engine that the layout separation deliberately keeps out, which is too high a price for a cosmetic gap that /favicon.ico already covers by convention. Reported by the sjm-claude-code site agent 2026-08-07 alongside SM235. Cosmetic rather than broken - a root favicon.ico still works by convention. Verified: lazysite core emits no icon link anywhere, and the stock layouts are not in this repository, so the fix likely belongs to the layout catalogue. Recorded here because the decision about WHERE it belongs is a core one."
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

## DECIDED 2026-08-08: it belongs in the layouts

The operator chose the layout option. Nothing changes in lazysite core, and this
request is parked here rather than closed, because the work is real - it has just
moved to a repository this one does not contain.

**What that means in practice.** Each stock catalogue layout gains a
`<link rel="icon">` in its head, and the layout-authoring checklist gains the
requirement so a new layout cannot reintroduce the gap. A site's icon then
arrives when its layout is next updated, rather than all at once.

**Why not the engine option**, which would have fixed every existing site
immediately: it puts a piece of `<head>` markup back into the engine, and the
layout separation exists precisely to keep it out. Buying a fleet-wide fix at the
cost of that boundary is the wrong trade for something the filing itself
describes as cosmetic - a root `/favicon.ico` is already found by convention, so
nothing is broken today.

Worth being clear that the decision has a cost: the standing practice of checking
every granted site has a favicon stays a per-site check for now, and sites on
older layouts keep relying on the convention until their layout moves.

## The options that were weighed

Kept as the record of what was considered. Two places it could live, and they are
not equivalent.

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
casually just because it is convenient.

## The work, in the layouts (CHOSEN)

- Add `<link rel="icon">` to each stock layout head, resolving a site-declared
  path where one exists and the conventional root path otherwise.
- Make it part of whatever layout-authoring checklist exists, so new layouts do
  not reintroduce the gap.

## The engine shape, NOT taken

Recorded so a future reader knows it was considered rather than overlooked, and
so the same proposal does not arrive again as if new.

- A site variable for the icon path, defaulting to the conventional root file
  when unset and absent when the site sets it empty.
- Emitted only where the layout asks for it, so a layout that wants full control
  of its head keeps it.

If this is ever revisited, the narrower form is the one to revisit: exposing a
resolved *variable* without emitting any markup is arguably not a breach of the
layout separation at all, since the engine already resolves `site_name` and the
rest. That reading was available and the layout route was still preferred.

## Not in scope

- Generating or converting icon artwork. That is site work.
- Changing how `/favicon.ico` is served.
