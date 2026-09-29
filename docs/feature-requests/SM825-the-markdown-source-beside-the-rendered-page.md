---
id: SM825
title: "SM825: the markdown source, exposed beside the rendered page"
subtitle: "Accepted 2026-09-10, second in the knowledge-standards sequence and expected to be near-free - which is the thing the audit has to confirm before any work is committed to it. Agents consuming a site prefer the source to the rendering, and the source already exists; the question is whether exposing it is a serving change or a gating one."
brand: plain
standard-margins: true
status: candidate
status-note: "AUDITED 2026-09-29, and the answer is NOT near-free - which is what the audit was for. (1) The .md is NOT reachable: md is the first entry on SM797's static-serve denylist, by a ruling of 2026-09-09, enforced on both the request extension and the canonical path. Exposing it is a named exception to a three-week-old ruling. (2) The static serve DOES gate - _acl_refused, SM223's work - but only on the PER-PATH ACL store; it never reads the page. A page declares access in FRONT MATTER with auth:, so dropping md from the denylist gives the SM460 shape exactly: gated as a rendering, world-readable as a source. auth: is on 27 of the 64 pages the engine ships. (3) draft: is the same mechanism and the same answer. (4) Measured what a verbatim .md would publish first: auth on 27 pages, query_params on 5, tt_page_var on 2, payment_address on 2, form, api and auth_groups on one each. AND A CORRECTION TO THIS FILING: it says front matter carries read: lists, and it does not - there is no read: page key and no shipped page has one; per-path reader lists live in acls.json. The disclosure is smaller than filed and is still an access-control fact on 42% of pages. RECOMMENDATION: build it as an EMITTER ON THE RENDER PATH rather than an exception to the denylist, so the gate is the page's own by construction and SM797 needs no reconciling; sized S for the emitter plus the llms.txt links. What remains a RULING rather than a size: which front-matter keys a source alternate may carry - an allowlist, because a denylist exposes the next key somebody adds."
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

# THE AUDIT, DONE 2026-09-29. Verdict: NOT near-free.

Measured from the source and from the shipped content, not reasoned about. Each
answer names where it was read.

## 1. Is the `.md` already reachable? NO, and by a ruling.

`md` is the FIRST entry on SM797's static-serve denylist
(`lazysite-processor.pl`, `%STATIC_DENY`), in the group commented "the engine's
own inputs - md url brief: pages render, never download". That denylist is a
**ruling of 2026-09-09**, three weeks before this audit, and it is enforced twice:
on the request's extension and again on the canonical resolved path, because a
symlink can carry an innocent name to a denied target.

So this is not "expose a file that is already there". It is a named exception to a
fresh ruling, which is what the filing suspected, and the exception has to be
written so the two agree rather than so one quietly wins.

## 2. Gating: the serving path has A gate, and it is the WRONG ONE.

`_serve_content_static` ends with `_acl_refused( $real, $uri )` - so a static file
IS gated, which SM223 built. But `_acl_refused` reads exactly one store:
`lazysite/auth/acls.json`, the PER-PATH ACL. It never opens the page.

A page declares its own access in FRONT MATTER, with `auth:` (and `auth_groups:`),
read during render. Those are two different mechanisms over two different stores,
and only one of them is on the static path.

**So the naive route - drop `md` from the denylist - produces the SM460 shape
exactly:** a page with `auth: required` and no path ACL rule is gated as a
rendering and world-readable as a source. Not a hypothetical: `auth:` appears in
the front matter of **27 of the 64 pages the engine ships**.

## 3. Drafts and unpublished pages: the same answer, for the same reason.

`draft:` is honoured by the render path. The static path does not read front
matter, so it cannot honour it. Whatever serves the alternate has to consult the
page, not the path - which is the same requirement as 2 and not an extra one.

## 4. What is in the source that is not in the render: measured.

All 64 shipped starter and manager pages carry front matter. Counting the keys
(`tmp/sm825-audit.pl`), the ones a verbatim `.md` would publish for the first
time:

| Key | Pages | What it exposes |
| --- | --- | --- |
| `auth` | 27 | whether the page is gated, and how |
| `query_params` | 5 | the allowlist a prefill reads from |
| `tt_page_var` | 2 | the data bindings behind the page |
| `payment_address` | 2 | a payment address |
| `form` | 1 | the form name, hence its handler binding |
| `api` | 1 | that the page is a raw endpoint |
| `auth_groups` | 1 | the name of a group |

`title`, `subtitle` and `register` are already in the rendering and disclose
nothing new.

**AND ONE CORRECTION TO THIS FILING.** It says "Front matter carries `read:`
lists". It does not: there is no `read:` page key, and no shipped page has one.
Per-path reader lists live in `acls.json`, which a source alternate would not
carry. The disclosure is `auth:` and `auth_groups:` rather than a reader list -
smaller than filed, and still an access-control fact on 42% of shipped pages.

## What this means for the work

The cheap version does not exist. A markdown alternate needs BOTH:

1. **A filtered body, not the file.** Front matter is where the problem is, so
   serve the prose with the front matter removed, or with an allowlist of keys
   (`title`, `subtitle`, `description`) - a denylist here repeats the mistake
   SM797's ruling avoided, because the next key somebody adds is exposed by
   default.
2. **A serve path that asks the page.** The alternate has to resolve the page,
   read its `auth:` and `draft:`, and refuse on the same terms as the rendering -
   at which point it is not a static serve at all, it is the render path with a
   different emitter. That is where the cost is, and it is the honest place to
   put it: one answer to "may this visitor see this page", not two.

My recommendation is to build it as an **emitter on the render path** rather than
an exception to the static denylist: the gate is then the page's own, by
construction, and SM797's ruling stays intact with nothing to reconcile. Sized S
for the emitter and the llms.txt links, plus whatever the RM decides about which
front-matter keys a source alternate may carry - which is a ruling, not a size.

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
