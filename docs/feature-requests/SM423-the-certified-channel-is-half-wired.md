---
title: "SM423: the certified channel is half-wired"
subtitle: "ADR 0010 added a fourth rung and wired install.pl, the CLI, release.sh and the compliance gate. It did not wire the manifest builder or the apt repo - so `release.sh --certified` dies before it reaches the gate it exists to run."
brand: plain
standard-margins: true
status: candidate
status-note: "FOUND 2026-08-20 by a method-corpus review of ADR 0010, hours after that work landed, and every finding is verified. THE BLOCKING ONE: tools/build-manifest.pl still validates the channel against edge|beta|stable and dies on 'certified', while release.sh passes --channel unconditionally - so the FIRST certified cut fails at manifest build, after the compliance gate has already passed. A rung that cannot be cut is a rung that does not exist, and the reviewer found it by reading the corpus rather than by cutting, which is the only reason it was not found by an operator. ALSO: build-apt-repo.sh rejects the suite the same way; two starter docs still teach a three-rung ladder (update-channel.md and config.md's Manager UI note string); and t/tools/43's exhaustive per-site matrix still enumerates only three rungs, so certified is covered by its own subtest and NOT by the matrix that exists to be exhaustive. SIZE: S, and it is finishing what ADR 0010 started rather than new work. WHAT IT SAYS ABOUT THE ORIGINAL CHANGE: I wired every place that CONSUMES a channel and missed the two that PRODUCE an artefact carrying one - the tests passed because no test cuts a certified release."
---

# The five

1. `build-manifest.pl` rejects `certified` - **the first certified cut cannot
   complete**, and fails after the compliance gate has passed, which is the
   most expensive place to discover it.
2. `build-apt-repo.sh` rejects the suite, so the rung has no repo-level
   expression.
3. Two starter docs still teach three rungs, one of them a Manager UI string an
   operator reads on the Config page.
4. The ADR 0010 changelog bullet sits inside the released `## 0.10.17` section
   though it landed after the tag - and carries `(PENDING)`, so **neither
   t/lint/53 nor t/lint/65 sees it**: 53 ignores PENDING refs and 65 only
   checks entries carrying a SHA. A misfiled PENDING entry is invisible to both.
5. `t/tools/43`'s exhaustive matrix enumerates three rungs; certified rides a
   separate subtest, so the matrix is no longer exhaustive while still reading
   as though it were.

::: widebox
Finding 4 is a gap in a lint I wrote in this same session, for this exact
class. It pins entries that carry a SHA and says nothing about the ones that do
not - so "misfiled reads as shipped" remains true for every PENDING entry.
:::
