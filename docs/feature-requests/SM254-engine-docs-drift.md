---
title: "SM254 - Engine documentation has drifted from the engine"
subtitle: "Fourteen divergences found by source-validating the docs against the tree. Individually trivial; together they mean the documentation cannot be trusted without checking the code, which is the thing it exists to save."
brand: plain
status: candidate
status-note: "From a docs-audit note of 2026-07-26, produced by source-validating every claim while rewriting the public site. Never actioned; found and filed 2026-08-08. Spot-checked before filing: uninstall.sh and starter/registries/ genuinely do not exist, and DEVELOPER.md's test figure is stale. The value is less in the individual corrections than in the guards that would stop the same drift recurring."
---

# SM254 - engine documentation has drifted

## Why

Someone rewriting the public site validated every claim against the v0.9.15 tree
and found fourteen places where the documentation and the code disagree. None is
dangerous. Together they matter, because documentation that is wrong in fourteen
small ways cannot be relied on without opening the source - which is precisely
the work it exists to save.

Two were spot-checked while filing and both hold: `uninstall.sh` and
`starter/registries/` are referenced in engine docs and **do not exist in the
tree**, and `DEVELOPER.md` still quotes "≈2,700 tests" for a suite that has since
grown well past it.

## The findings

### Statements that are simply wrong

| Claim | Reality |
|---|---|
| `uninstall.sh`, `starter/registries/` referenced | Neither exists |
| DEVELOPER.md "≈2,700 tests" | Stale; the suite has grown since |
| FEATURES.md quotes a 147x cache-hit speedup | The recorded measurement is 155x |
| Preinstall snapshot attributed to `install.pl` | It lives in `install-hestia` |
| FEATURES.md quotes `Lazysite::Git`'s `@EXCLUDE` list | The real list is longer |
| FEATURES.md describes SM155 delegation | The shipped model is SM165 domain-derived scopes |
| SM179 P8 chrome i18n marked deferred | It shipped |
| SM179 spec names a `lang_source` front-matter flag | No such flag exists |
| SM140 analytics field list | Predates the implementation |

### Statements that are true but read wrong

| Claim | The misreading |
|---|---|
| SM133 static fallback wording | Can be read as doing SSI; it serves `.html` only |
| `::: include` described per the P4 claim | The shipped version is content-root-confined, i.e. stricter |
| SM120 source comment calls the per-page `theme:` pin "preview-only" | FEATURES.md and the code treat it as a general per-page override |

A wrong-but-plausible statement costs more than an absent one: SM242 was
precisely this failure, where "re-activate to rebuild the mirror" was correct for
one site and damaging for another.

### Behaviour worth a decision, not just a correction

**Theme name collision is handled two ways.** A theme upload installs under a
date-prefixed name; `create_theme` (SM205) refuses. Both are defensible; having
both, undocumented, means an agent cannot predict which it will get. Decide, then
document the decision.

**Packaged-install registry defaults to channel `edge` while the seeded conf says
`stable`.** Two defaults for one question, disagreeing. Whichever is right, they
should not differ.

### Site-package warts, still present

From the providers migration of 2026-07-24: token clients cannot download site
packages; `apply` carries the source's `site_url`/`site_name` onto the target
(SM193 fixed the default on the control-API path, but the MCP and CLI paths still
lack `adopt_identity`); and apply installs the layout without creating the
`/lazysite-assets` mirror.

That last one is the same family as SM241, which fixed `domain-set`. Worth
checking whether SM193's mirror-on-apply covers it or whether a gap remains -
the report says it does not.

## What to do

**Correct the fourteen.** Mechanical, and it should be one pass rather than
fourteen commits.

**Then stop it recurring**, because a docs sweep that is not defended decays
again. Three of these are mechanically checkable and worth guards:

- **Dead path references.** A lint that greps the docs for `path/like/this` and
  fails when the path does not exist would have caught `uninstall.sh` and
  `starter/registries/` the day they were removed.
- **The test count.** Either derive it, or drop the number and say "see the
  gate output" - a figure nobody updates is worse than no figure.
- **Retired terminology.** The SM120 "preview-only" comment is adjacent to the
  existing retired-terms lint; extending that list is cheap.

The rest - measurements, feature descriptions, spec-versus-shipped - are judgement
calls that no lint will catch, and their real defence is that a claim gets
re-validated when the feature next changes.

## Verification

- Every finding above is either corrected or recorded as a deliberate decision.
- The two dead paths are gone from the docs, and a lint fails if a new one
  appears.
- DEVELOPER.md's figure is current or removed.
- The two behaviour questions (theme collision, channel default) have answers,
  not just descriptions.

## Not in scope

- The public lazysite.io site, which was already corrected and is what produced
  this list.
- SM193's site-package work beyond confirming whether the mirror gap remains.
