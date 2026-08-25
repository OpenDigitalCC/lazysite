---
title: "SM574: the field practice ships with every site"
subtitle: "The site agent keeps two best-practice references for building sites and apps on the engine. They live in the agent's own projects, so every other agent that connects starts without them. The engine already serves briefings to agents; the practice belongs among them."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.33: tools/import-field-practice.pl PULLS both sources from their canonical paths and writes starter/docs/ai-briefing-practice.md (46,101 bytes, 7,829 words, 30 H2 sections). No capability-list edit was needed: lib/Lazysite/Capabilities.pm discovers docs.briefings by slug, so any ai-briefing-*.md in the docroot is indexed on arrival. All four design constraints are built. (1) The five version-dated sections keep their before/after columns and each carries a marker naming the engine version the page was generated for - which required rewriting the sources `datatable` fences as pipe tables, because that fence is a table in the PDF pipeline and a CODE BLOCK when the engine serves it, so an unchanged copy would have lost the columns in the act of shipping them. (2) The two field-scar sections ship marked version-independent, and a rename upstream is a hard error in the import rather than a silent downgrade to unmarked. (3) The provenance framing says these are one agent's field notes from building and breaking real sites, a companion to the reference briefings and not a specification, and that where they conflict with the reference docs the reference docs win and the conflict is a bug in the notes - with the agent, the import date and each source's own last-changed date. (4) "Keeping this current" is dropped, replaced by one line saying updates come from re-running the import. t/lint/88 asserts each of those, the engine stamp (VERSION or NEXT_VERSION, nothing hand-typed), the recorded source checksums, and a body-sha256 the page carries for itself so an edit is caught on a machine where the sources do not exist; where they are readable it re-runs the import and compares byte for byte. Seen to fail under four sabotages: edited prose, a deleted before/after row, a retyped engine version, and a source that moved on. LEFT TO THE AGENT THAT OWNS THOSE FILES: a pointer from starter/docs/ai-briefing-building-sites.md and an entry in starter/docs/index.md - the new page is indexed automatically but nothing links to it yet. REQUESTED BY THE OPERATOR 2026-08-25: the site agent maintains AUTHORING-PRACTICE.md in the lazysite-sites project and APP-PRACTICE.md in the lazysite-apps project - the living record of what building real sites and apps on the engine taught, kept current as the field passes continue. The operator wants them INCLUDED in the documentation the engine serves to agents over API and MCP (starter/docs/ai-briefing-*.md, indexed by describe_capabilities under docs.briefings), updated regularly. CANONICAL SOURCES (from the site agent): /srv/projects/lazysite-sites/AUTHORING-PRACTICE.md (3982 words, 11 H2 sections, sites and content) and /srv/projects/lazysite-apps/APP-PRACTICE.md (2988 words, 15 H2 sections, apps and data); both are H2 sections that lift whole with no cross-references; the import PULLS from those paths, which sit outside this tree. PLANNED for 0.10.33 under SM516: a starter doc /docs/ai-briefing-practice generated at build time by a tools/ import script that writes a provenance header (source paths, agent, date, engine version), with a lint that the served copy matches the imported sources, so field learning reaches every connecting agent and never drifts from what the agent actually practises. Design constraints: version-dated sections keep their before/after columns and the page states the engine version it was generated for; field-scar sections ship framed as version-independent; the provenance framing says these are one agent's field notes and the reference docs win on conflict; the author-facing 'Keeping this current' section is dropped or replaced by a pointer. Proving test: t/lint asserting starter/docs/ai-briefing-practice.md carries the provenance header and framing, states the engine version, and matches its import sources' checksums."
---

# What exists

The engine serves a briefing set to every connecting agent:
`starter/docs/ai-briefing-*.md`, indexed by `describe_capabilities` under
`docs.briefings`, and the MCP server instructions point at three of them
before a page is touched. They are the engine's account of itself.

The site agent keeps a second account, in two files outside this tree:

| Source | Size | Covers |
|---|---|---|
| `/srv/projects/lazysite-sites/AUTHORING-PRACTICE.md` | 3982 words, 11 H2 sections | sites and content |
| `/srv/projects/lazysite-apps/APP-PRACTICE.md` | 2988 words, 15 H2 sections | apps and data |

Both are built from H2 sections that lift whole, with no cross-references
between sections. They are read by one agent.

# The gap

Field learning stays with the agent that learned it. A new partner
connecting to a new site starts from the engine's briefings alone and
relearns the practice one mistake at a time.

# The mechanism

- **Imported, with provenance.** A `tools/` import script PULLS the two
  source files from their canonical paths and writes
  `starter/docs/ai-briefing-practice.md` with a provenance header naming
  the source paths, the agent, the date and the engine version. Run at
  build time, so a release carries the practice as it stood.
- **Indexed.** The new briefing appears under `docs.briefings` beside
  the others, and the building-sites briefing points at it.
- **Pinned.** A lint asserts the served copy carries the provenance
  header and matches its import sources' checksums, so the texts never
  drift.
- **Refreshed.** The import runs as part of the release, and an
  operator can run it between releases.

# Design constraints

- **Version-dated sections keep their shape.** Sections such as "A db:
  binding has a row ceiling, and it changed in 0.10.30" and "WebDAV
  writes that leave something stale" describe behaviour that differs by
  engine version and are written as before/after tables on purpose. The
  served page keeps the before/after columns AND states the engine
  version it was generated for: a half-migrated estate is the normal
  state, and the agents on older sites need those columns most.
- **Field-scar sections ship, framed as such.** "Things that look
  equivalent and are not" and "Verify like this" hold regardless of
  version and are the most useful part of the text. They are served
  with a line saying they are version-independent.
- **Provenance framing beyond agent and date.** The header says: one
  agent's field notes from building and breaking real sites, and a
  companion to the engine's reference docs rather than a specification;
  where the notes conflict with the reference docs, the reference docs
  win and the conflict is a bug in the notes.
- **Author-facing text stays with the author.** The "Keeping this
  current" section (instructions to the author) is dropped from the
  served copy, or replaced by one line pointing at where updates come
  from.

# Proving test

A `t/lint` test asserting `starter/docs/ai-briefing-practice.md`
carries the provenance header and the provenance framing, states the
engine version it was generated for, and matches the checksums of both
import sources.
