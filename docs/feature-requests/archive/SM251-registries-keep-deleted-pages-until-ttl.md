---
title: "SM251 - A deleted page stays in the sitemap until the registry TTL expires"
subtitle: "Self-healing, so not broken - but an agent that deletes a page and checks the sitemap cannot tell 'stale' from 'failed', and agents delete more than people do."
brand: plain
status: shipped
status-note: "IMPLEMENTED in the 0.10.4 edge line (2026-08-09, commit 42786e4). Reported by the sjm-claude-code site agent 2026-08-08 as the smallest of five items, explicitly minor. Filed because the cost is ambiguity rather than breakage: the state is correct-eventually and indistinguishable from a failure while it lasts. A briefing note would discharge it; pruning on delete would remove it."
---

# SM251 - registries keep deleted pages until the TTL

## Why

Deleting a page leaves its entry in `sitemap.xml` and `llms.txt` until the
registry TTL expires and they regenerate. A direct PUT of a corrected file holds,
and the next regeneration agrees with it, so the system converges on its own.

The cost is not breakage, it is **ambiguity**. An agent deletes a page, checks
the sitemap, and sees the URL still listed. It cannot tell:

- the registry is stale and will catch up, from
- the delete did not take, from
- something else republished the page.

So it either waits without knowing how long, re-deletes, or reports a defect that
does not exist. All three cost time, and the third costs an operator's time too.

Not MCP-specific - the same is true of a manager delete - but it surfaces more
now, because agents delete more than people do.

## Two ways to discharge it

**Say so.** A line in the publishing briefing: a deleted page may remain in the
generated registries until they regenerate, this is expected, and here is how
long. Cheapest, and it converts an ambiguous observation into an expected one,
which is the whole cost.

**Prune on delete.** Remove the entry when the page goes, so the registries never
disagree with the content tree. Cleaner, and it costs a registry rewrite on every
delete - fine for a single delete, worth thinking about for a bulk one, where
pruning once at the end is the right shape.

Recommend the note first, because it is minutes rather than hours and removes the
whole reported cost. Pruning is worth doing if registry freshness turns out to
matter elsewhere - SM244's stale-entry reporting is adjacent and might make the
case.

## Verification

- The publishing briefing states the behaviour and the window.
- If pruning is built: deleting a page removes its registry entries, a bulk
  delete rewrites the registries once rather than per page, and nothing else in
  the registries changes.

## Not in scope

- Changing the registry TTL.
- Regenerating registries on every content write.
