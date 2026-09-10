---
id: SM823
title: "SM823: an ingestion plugin with pluggable sources, Silex first"
subtitle: "A scoping briefing that has been sitting in the inbox since August, filed now so it is tracked rather than remembered. It asks for an ingestion plugin with a pluggable SERVICE interface and Silex as the first service, chosen because it emits real HTML and CSS so the interface can be proved without an external protocol. Not scoped - and it is the concrete case that would make `plugin` the right word again, which bears directly on SM817."
brand: plain
standard-margins: true
status: candidate
raised: 2026-08
raised-by: claude.ai session, via the release manager's inbox
area: apps
---

# What it asks for

Two things: an **ingestion plugin** with a pluggable **service** interface, and
the **first service - Silex** - with its integration document in the existing
`/docs/integrations/` namespace. Sources already in view beyond Silex include
Figma.

Silex is deliberately first because it is "the easiest honest case": it emits
real HTML and CSS, so a service can be written and proved end to end without any
external protocol standing in the way. That is a good choice of exemplar and the
same instinct [[SM222]] used in taking the daemon first - prove the contract on
the member that needs least scaffolding.

It states its own status as **for scoping**, audit-first per the standard working
method, and says it does not change that method. It sits under
`docs/practice/app-foundation.md` (also at
`/srv/projects/lazysite-apps/APP-FOUNDATION.md`) as the machinery for that
document's Stage 1, Ingest - both files exist and the reference resolves.

# Why this matters to the vocabulary decision

[[SM817]] rules that `plugin` is the wrong word for the fourteen bundled units,
and reserves it deliberately: "if third-party authoring ever becomes feasible - a
subsystem written elsewhere and dropped in - `plugin` is the correct word for
that, and it would then be free."

**This briefing is that case, arriving from the other direction.** A pluggable
source interface is precisely a thing where a service can be authored and added
without the engine knowing about it in advance. So the taxonomy SM817 proposes
would land as:

- **extensions** - the bundled units that extend the core renderer.
- **plugins** - things genuinely written elsewhere and plugged in, of which
  ingestion sources would be the first.

That is a better outcome than either word alone, and it means SM817 should be
built before this rather than after, so the ingestion work is named correctly on
the day it lands rather than renamed later.

# Related prior art in this tree

[[SM208]] established the `/docs/integrations/` namespace and a Figma helper,
which is where this briefing says its integration document belongs. Anyone
scoping this should read SM208 first - it is the closest existing thing and the
briefing assumes its namespace.

# What is asked of the release manager

Nothing yet beyond a decision on **when**. It is a scoping brief, not a
specification, and it has waited since August without cost. The two things worth
settling when it is picked up:

1. **Whether it waits for [[SM817]].** Recommended: yes, and not for long - the
   rename is a release's work and naming this correctly on arrival is cheaper
   than renaming it after.
2. **Whether the service interface is the same mechanism as the extension
   contract**, or a second one inside it. The briefing implies a service
   interface nested inside a plugin, which is two levels of pluggability; that
   may be right for sources and is worth stating deliberately rather than
   inheriting from the briefing's phrasing.

# Provenance

`inbox/briefing-ingestion-silex.md`, dated August 2026, read in full 2026-09-10.
Filed rather than scoped. The existence of both foundation documents and SM208's
namespace were checked here; no prior filing covers ingestion or Silex.
