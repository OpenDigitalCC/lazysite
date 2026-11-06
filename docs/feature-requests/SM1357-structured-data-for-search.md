---
id: SM1357
title: "SM1357: structured data for search engines and AI search"
subtitle: "Every site's facts (what it is, where, when it is open, what it offers) are published as schema.org JSON-LD generated from its data tables and schedules, so search engines and AI search read them without anyone writing markup."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-06
raised-by: "release manager (SM1350 discussion)"
area: seo
status-note: "Filed 2026-11-06 under SM1350. The engine emits no JSON-LD today."
---

# Proposed

- **A mapping file:** it maps a data table or schedule to a schema.org type and its properties. An app ships the mapping for its market; the engine ships none for any market.
- **Emitted on the page:** the engine adds the JSON-LD to the pages the mapping names, from the rows that are available now. The site's own details (name, address, contact, hours) form the organisation entry.
- **Freshness:** a change to a row or schedule refreshes the pages that carry its data (the same invalidation as content).
- **Also covered:**
  - a sitemap including every public page;
  - page titles and descriptions checked by `lazysite check`;
  - an AI-readable summary page or file, if ruled.
- **Validation:** `lazysite check` validates the emitted JSON-LD against the mapping's types.

# Questions for ruling

1. Should the AI-readable summary (an `llms.txt` style file) be generated alongside the sitemap?
