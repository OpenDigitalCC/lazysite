---
title: "The next release: what is queued, and what stable needs after it"
subtitle: "0.11.11 beta, then a stable. What each item is, what decides it, and what is deliberately held back. Kept here rather than in a conversation, because a plan that lives in a transcript is a plan the next reader cannot check."
brand: plain
standard-margins: true
---

# 0.11.11 - beta

## Landed and ready

| Item | What |
| --- | --- |
| SM725 | A named-key table declaring `timestamps` could not be created at all |
| SM726 | Six save behaviours, written down; Domains as the exemplar |
| SM728 | A control declares its impact, so rules about colour and confirmation can be checked |
| SM729 | The page-parse guard reaches the WebDAV stack, not only MCP |
| SM730 | Filed: a blocked upload says "Blocked target" and names nothing |
| SM731 | The practice import refuses to publish a client's name |
| SM732 | The PDF render has a caller at last - SM706 shipped without one |
| SM733 | The practice sources move into the repo that ships them |
| SM735 | A generated documentation index, so the corpus can be discovered without being read |

## Added to this release: SM734

**Theme assets compile to the docroot, so a content-root domain never receives
its CSS.** A multi-site domain with a `content_root` renders unstyled however
often its theme is activated, while the manager preview shows it correctly.

**It needs a decision before it needs code**, and the decision is not obvious:

- **Compile into each domain's content root.** n copies, each activation writing
  several. Self-contained, and consistent with SM286 - the engine asks nothing
  of the front end.
- **Serve from the instance docroot by a front-end rule.** One copy, but it asks
  something of the front end, which **SM286 refuses** as a matter of standing
  policy.

The first is almost certainly right on SM286 grounds alone. It is written down
as a choice because "obvious" is how a standing policy gets overturned without
anyone noticing they did it.

**Scope, before estimating:** every path under `/lazysite-assets/` on such a
domain, not only `main.css`, and on every release since the asset mirror
existed. Assume such a domain has never been styled rather than that it
regressed.

**And the outcome test must use the live host.** The manager preview renders
through the engine while the live host serves a static file, so the preview
passed throughout this defect's life and would pass again over a bad fix.

## Held back from this release, deliberately

The **page conversions** for SM726 and SM728 - seven pages of save behaviours,
199 controls of impact declaration. Both are decided as **edge** work, with the
reasoning recorded in each filing: the last change that touched every manager
page produced ninety-five review items, and our gate is weakest on exactly that
class. The ratchets exist so the conversion happens against a check rather than
against a memory.

# Then stable

Compliance on `--channel stable` reports **0 blocking**. The three items that
blocked in August are gone, so stable is not gated by compliance any more. What
remains is three things:

**1. The bench baseline, and it forces a deferred decision.** Stable adds a
warning the other channels do not: *re-capture at a stable cut*. The writer
**refuses**, because `verify_token_ms` sits at 1.48x - measured on a quiet host,
so it is real and not contention. Either `--accept-regression`, which
permanently redefines the slower number as correct, or close SM685. **This is
the only stable-specific engineering item.**

**2. Records, owned by the release manager.** The unsigned conformity
declaration, the significant-change register, and the restore rehearsal - which
`PATH-TO-STABLE.md` names as required per stable cycle and which is older than
the last stable cut. Two obligations fall due 2026-09-11.

**3. A field pass on the beta.** Including the composed-PDF test that has been
deferred twice for environmental reasons and is now genuinely runnable: `whole`
with all parts readable expects one PDF; `broken` expects a refusal **naming the
part**, not a shortened PDF.

# Open questions carried, not answered

- **SM729's WebDAV gap** is closed, but whether the guard belongs in the shared
  module or in whatever both stacks come to share is SM430's larger question.
- **SM735 indexes this repository only.** Documentation also lives in the
  layouts catalogue, a running site's published pages, and the website. A
  cross-tree index needs each tree to expose a listing the others can consume -
  a design question, not another script.
- **MCP has no convention for returning a binary body**, which is why `page-pdf`
  has no MCP twin. Recorded as undecided rather than skipped.
