---
title: "SM413: the homepage reports a version three releases old"
subtitle: "On edge.explore, / reports 0.10.13 while every other page reports the current build - surviving releases and cache clears. Cause not established. The only unexplained field anomaly on the beta path, and the release manager is taking the look."
brand: plain
standard-margins: true
status: candidate
status-note: "LOCATED 2026-08-20, by the field: a durable ENGINE RENDER-CACHE entry for /, produced under 0.10.13, served through FOUR deployments (0.10.14-0.10.17), cleared only when the operator manually invalidated the index page - after which every page agreed at 0.10.17. The response carried no-cache/must-revalidate/Vary: Cookie with x-lazysite-front present, so no intermediary was serving stale: the engine re-served its own stale artefact per request. The suspects list is resolved to its first family (a render nothing re-renders: the source never changed, and nothing else invalidates), and the earlier 'survives cache clears' observation needs one caveat - the clears observed were not shown to cover the index page specifically. WHAT REMAINS IS A DECISION, not a diagnosis: should an upgrade invalidate rendered pages (the field's framing: the first impression of the new build is the old build, on the page that gets looked at most) - or if deliberately not, where is the operator told to do it? With the release manager as a beta-gating question. FIELD CAVEAT RECORDED: the site agent's 0.10.14-0.10.16 validations included homepage reads served from the stale render; those specific conclusions are being re-run against 0.10.17; their new lzs-probe.sh version check (three pages, fails loudly on disagreement) is what caught this. FILED 2026-08-19 from the site agent's field observations; INVESTIGATION OWNED BY THE RELEASE MANAGER (their call, 2026-08-19, look scheduled next day). Recorded now so the look starts from the assembled facts rather than two agents' scattered reports, and so the beta promotion record has a ref to cite - promote-with-waiver or hold is a decision this filing exists to carry. NOTHING in here is diagnosis; the suspects list is prior art from the cache work, not evidence."
---

# Quantified overnight (2026-08-19, second field pass) - DATA, not diagnosis

**2 of 11 pages on edge serve 0.10.13**, three releases back - so this is not
a homepage anomaly, the homepage is the visible instance of something wider.
And the agent's sharper point: **edge is the BEST case.** Pages re-render when
their SOURCE changes, and edge has been edited all week. A real site untouched
for months would serve entirely pre-upgrade renders after a fleet rollout -
including any head-contract change the release carried.

Which suggests the question under the question: **does anything invalidate the
render cache on a release?** If nothing does, the observations stop being
anomalous and start being the designed behaviour meeting a fleet for the first
time - and the earlier "survives cache clears" is the remaining puzzle piece,
since a clear SHOULD force the re-render that a release does not.

# The observations, as reported

All from the site agent on edge.explore, 2026-08-19:

- `/` reports **0.10.13** in its rendered chrome while every other page on the
  same site reports the current build - first counted at one release behind,
  now three, so it is not converging on its own.
- It has **survived releases and cache clears** - whatever regenerates every
  other page is not regenerating this one, or something serves ahead of the
  regenerated copy.
- The agent counted rather than re-filed; this filing is the record.

# Related, possibly the same shape

[[SM371]]: `/402.html` carrying a visitor-supplied query string in its
canonical, **also surviving cache clears**, source unidentified, fix shipped
untested. Two artefacts outliving invalidation on the same instance may be one
mechanism wearing two hats - or a coincidence. Establishing which is part of
the look.

# Suspects (prior art, NOT evidence)

From the cache work's known gotchas, in no order:

- A cache file for `/` owned by a different identity than the current writer -
  a regeneration that fails on permissions can be silent, leaving the old copy
  serving forever (the mixed-identity umask case the cache writer documents).
- SM367's invalidate distinguishes cleared / nothing-cached / no-such-path -
  what does it actually report for `/` on that instance? A "cleared" that
  cannot name the file it cleared is the SM377 class.
- The front door or a template serving `/` from a path the invalidation does
  not map - the index special case (`/` vs `/index.html` vs `/index.md`
  resolution) is the one URL with three spellings.
- Version string baked into a layout-level artefact with the 10-year static
  cache (`?v=` busting missed for one asset class).
- The dev-server-pollution gotcha: runtime state written INTO a docroot by a
  tool, later shadowing the engine's own output.

# What the look needs from the instance

The three questions that discriminate between suspects, all read-only: what
file actually serves `/` (mtime, owner, content version string); what
invalidate-cache reports for `/` specifically; and whether `/index.html`,
`/index.md`-rendered and `/` return the same bytes.

# Why it gates beta

Not because a stale homepage is catastrophic - because it is **unexplained**,
on the most-visited page, in the serving path. The promotion record should
carry either its explanation or an explicit waiver with this ref on it.
