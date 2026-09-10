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

# EXTENSION OR CORE, researched 2026-09-10: core, and not for want of trying

Extension was preferred and it does not fit, for reasons that are about the work
rather than the principle.

**Serving a URL is not something an extension can do.** Extensions expose
`actions` reached through the manager API, MCP or the daemon. Nothing in the
contract claims a path, a suffix or a request. A `.md` alternate is a request the
front door has to answer.

**And `llms.txt` is generated in the core processor** and referenced from eight
surfaces - the processor, the front door, the manager API, MCP, DAV, Files, Lang
and the check tool. Adding `.md` links to it is an edit to core generation, not
an extension writing its own file.

**The one extension-shaped part** is the `<link rel="alternate">` in `<head>`,
which needs the same render-time registry [[SM824]] does and does not exist yet.
That is a small piece of a mostly-core change, and splitting the filing across
that boundary would cost more than it explains.

**And placement is not this filing's hard part anyway.** The audit still has to
answer what must be WITHHELD from a source alternate: front matter carries `read:`
lists, `register:` handling and operator notes, so serving the file verbatim
publishes a page's access-control configuration alongside its prose. Plus
[[SM797]]'s denylist exists precisely to refuse source files, so this is a named
exception to a rule ruled on the day before. Those are core questions wherever
the code lives.

**Recommendation: core, and sequence it after [[SM824]]** - not because it depends
on it, but because SM824 establishes the render hook that the alternate link
should use rather than this filing inventing a second way to reach `<head>`.
