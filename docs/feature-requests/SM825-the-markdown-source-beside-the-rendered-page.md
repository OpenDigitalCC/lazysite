---
id: SM825
title: "SM825: the markdown source, exposed beside the rendered page"
subtitle: "Accepted 2026-09-10, second in the knowledge-standards sequence and expected to be near-free - which is the thing the audit has to confirm before any work is committed to it. Agents consuming a site prefer the source to the rendering, and the source already exists; the question is whether exposing it is a serving change or a gating one."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-10
raised-by: release manager, from the knowledge-standards survey
area: discoverability
---

# What is asked

Expose each page's markdown alternate - the `.md` source beside the rendered
HTML - and add those links to `llms.txt`, which the engine already generates.

The recommendation marks this **VERIFY, THEN EXPOSE**, and calls it likely
near-free after audit. That ordering is the whole of the filing: it is cheap if
the source is already servable and gated correctly, and it is not cheap at all if
it is not.

# What the audit must settle, because "near-free" is a claim not a fact

- **Is the `.md` already reachable?** [[SM797]] is a denylist for the static
  serve, and source files are precisely what it exists to refuse. So this is
  not "expose a file that is already there" - it is a deliberate, named
  exception to a rule just ruled on, and the two must be written to agree.
- **Gating.** A page behind `auth: required` must not have a world-readable
  source alternate. Whatever answers the `.md` has to consult the same gate as
  the rendered page, at the same time, and a test has to prove the refusal -
  the SM460 shape, where a scan could see a gated section.
- **Drafts and unpublished pages.** Same question, different store.
- **What is IN the source that is not in the render.** Front matter carries
  `read:` lists, `register:` handling, internal comments and operator notes. If
  the alternate serves the file verbatim it publishes the access-control
  configuration of the page along with its prose.

That last one is the reason this is filed rather than built. A markdown alternate
is trivially easy to serve and the interesting question is what has to be
**withheld** from it.

# Provenance

`inbox/knowledge-standards.md`, Recommendation 4, accepted 2026-09-10. Sequenced
after [[SM824]] by the recommendation itself.
