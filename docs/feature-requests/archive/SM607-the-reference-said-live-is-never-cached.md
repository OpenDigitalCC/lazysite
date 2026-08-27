---
title: "SM607: /docs/data-tables said `live` is never cached, and an agent reasoned correctly from it to a false conclusion"
subtitle: "The mode withdraws the mtime proof of freshness. It never touched the page's ttl:, which is the only freshness mechanism such a page has."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.0 (stable, 2026-08-26). FOUND 2026-08-26 during the pre-stable review of the site agent's practice notes, and the route by which it was found is the point. The agent wrote that `mode=live` opts a page out of caching whatever ttl it sets - then STOPPED THE RELEASE to say they had reasoned that from the reference and had not measured it. I measured it: a page with `db:products(mode=live)` and `ttl: 300`, a row changed underneath, serves the OLD value. It is cached, exactly like snapshot. THE SENTENCE THAT MISLED THEM WAS OURS: /docs/data-tables said `live` is `read on every request. The page is never cached`. The mechanism is that a db: binding withdraws the MTIME proof of freshness - a table has no timestamp that could prove a cached page current - and does not touch the page's ttl:, which is a separate branch and the only freshness mechanism such a page has. So `never cached` was only ever true of a page carrying no ttl:, which is the same trap the agent's own earlier claim fell into, one level up. WHY THIS IS FILED RATHER THAN QUIETLY PATCHED: an agent read a document we ship, reasoned correctly, and reached a false conclusion. If that only ever appears as a doc edit, the next agent repeats it. THE AGENT'S OWN OBSERVATION IS THE SHARPEST THING IN THIS FILING and is recorded in their words: what made the sentence convincing was that it AGREED with what they had already measured on ttl-less pages. A wrong reference sentence that happens to match your observations is not something a probe would catch - they only found the ttl branch because someone contradicted them. AND IT IS NOW DOUBLY WRONG: since SM604 every db: binding withdraws the mtime proof, so `live` and `snapshot` have no observable difference at all. The reference described a distinction the engine does not make. FIXED: the table states what each mode actually does, the note says plainly that the two currently coincide and why, and the previous wording is quoted rather than erased - a reader who acted on it needs to recognise it. THE VESTIGIAL MODE IS NOT RESOLVED HERE: giving `live` a real difference (bypassing the ttl branch) or removing it is a design decision for after the stable cut."
---

# What the reference said, and what happens

| | The reference said | Measured |
|---|---|---|
| `live` + `ttl: 300`, row changed | never cached, so the new row | **the old row** - cached for its ttl |
| `snapshot` + `ttl: 300`, row changed | cached for the ttl | the old row - identical |

# The mechanism, in one sentence

A `db:` binding withdraws the **mtime** proof of freshness, because a table
has no timestamp that could establish it. The page's `ttl:` is a different
mechanism and is untouched - so it is the only freshness bound such a page
has, and a page without one is re-rendered every request.
