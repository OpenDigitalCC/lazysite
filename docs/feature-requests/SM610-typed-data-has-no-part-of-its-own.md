---
title: "SM610: the data plugin exists in FEATURES.md only as changelog entries"
subtitle: "It is what the app examples rest on, and the only authoritative account of it is a version history. A use-case page had nothing to link to but a changelog."
brand: plain
standard-margins: true
status: shipped
status-note: "RAISED BY THE OPERATOR 2026-08-26 during the 0.11.0 stable prep. FEATURES.md carried the data plugin across a dozen version-history entries - 0.10.23 through 0.10.34, plus the domain scoping in this release - and nowhere as a subject. A reader wanting to know what a descriptor may say, or which doors write to a table, had to reconstruct it from a timeline written to record change rather than to explain a feature. That is backwards for what has become the load-bearing feature of the app-examples story. SHIPPED as Part IX - Typed data: tables, bindings and the write doors, covering the six things the operator named: the descriptor grammar, the binding grammar, the modes, the write doors, domain scoping, and safety exports. WRITTEN FROM THE REFERENCE AND THE CODE, not from the changelog, which is the point of having it. Two things in it are true and were not written down anywhere an author would look: that `snapshot` and `live` currently behave identically and the mode is not the decision - the page's `ttl:` is (SM604/SM607) - and that dropping a table splits across three capabilities on purpose, `manage_data` to list, `housekeeping` to drop, `purge` to delete the safety export, so one grant cannot both destroy a table and remove the evidence. THE PARTS WERE RENUMBERED rather than the new one being bolted on as VIIIa: data earns a number. IX through XIV moved up one, and the four prose cross-references were checked afterwards rather than assumed - one of them, the FastCGI pool pointing at 'Part IX', had NOT been rewritten because the substitution's guard against touching headings also skipped a reference followed by a dash. It pointed at Typed data until that was caught. Every remaining reference was then resolved against the heading it names."
---

# What it replaces

A reader asking "what may a descriptor say?" was previously served by
thirteen version-history entries describing what changed about descriptors,
in the order it changed. That is a record, not an explanation.

# What it covers

| Section | Answers |
|---|---|
| The descriptor is the schema | field types, `required`/`unique`/`max`, `key`, `indexes`, `writable_by`, `public`, `domain` |
| Bindings put rows on a page | the binding grammar, `.count`, `.field`, the row ceiling |
| Freshness is the page's `ttl:` | why a table has no provable mtime, and why the modes do not differ today |
| Four doors write to a table | control API, MCP, the data endpoint, form handlers - and how they differ |
| Domain scoping | `domain:`, what a confined caller sees, and why an unscoped table stays reachable |
| Dropping a table | the safety export, and the three-capability split |
