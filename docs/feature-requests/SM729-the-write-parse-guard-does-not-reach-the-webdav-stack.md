---
id: SM729
title: "SM729: the write-parse guard does not reach the WebDAV stack"
subtitle: "SM708 refuses an unparseable page on the MCP write path. Proved in the field: the same body is accepted over WebDAV, on a site where it genuinely renders wrong. Recorded as SM708's known limit; now measured, and needing a decision rather than an assumption."
brand: plain
standard-margins: true
status: candidate
---

# What was proved

The edge testing agent, 2026-09-02, against 0.11.10 beta.

| Body | Site | Surface | Result |
| --- | --- | --- | --- |
| stray `[%` in a paragraph | edge (auth off) | WebDAV PUT | 204 accepted |
| unmatched `[% END %]` in a paragraph | edge (auth off) | WebDAV PUT | 204 accepted |
| unmatched `[% END %]` in a raw `<div>` | **familyhq (auth on)** | WebDAV PUT | **201 accepted** |

The last row is the one that matters. familyhq is auth-enabled and interpolates
`[% auth_* %]`, so a page whose template does not parse **renders with every
substitution dead** there - and it was accepted without a word.

**The accept side is clean.** Six real edits to existing familyhq pages were all
accepted; no valid page was falsely refused. So SM708 is not over-refusing, it
is under-reaching.

# This was recorded, and is now measured

SM708's status-note already said the check "covers MCP writes ONLY - the manager
UI editor and WebDAV do not call `_validate_page`". That was written from
reading the code. This is the same fact established from outside, on a real
site, which is worth more: the limit is not theoretical and a partner writing
over WebDAV can ship a page that renders wrong with nothing telling them.

It is the two-write-stacks pattern that `docs/architecture` records as surface
drift - one guard, one stack, and the other stack unaware of it.

# A second finding, worth keeping

**On a site with the auth plugin disabled, `[%` is inert** - content is never run
through the TT pass, so SM708 is structurally inapplicable there. The edge
instance is such a site, which is why the first three probes prove nothing about
the guard.

That matters for whoever sweeps next: **only auth-enabled sites can trip this at
all.** A sweep across sites with auth off would return a clean bill that means
nothing.

# Answered: manager/MCP-only is NOT the intended position

This filing first offered "the guard is deliberately manager/MCP-only" as a
defensible reading. **It does not survive the code, and the evidence is a
decision already on record.**

**SM189 put a content guard on the WebDAV PUT path.** `lazysite-dav.pl:536`
refuses a page that ships raw HTML/SVG, and its own comment says what it is
doing: *"the same guard the manager/MCP save path applies
(`Lazysite::Manager::Common::raw_html_page_refusal`)"*.

So WebDAV is **not** treated as a dumb file transport here, and nobody has ever
decided that it should be. The opposite was decided, and built.

## The pattern already exists, fully worked out

SM189 answers every question SM708 would face:

- the refusal lives in a **shared module**, not in either stack
- **both stacks call it**, so they cannot disagree
- WebDAV reads a bounded head and refuses **before the rename**, so nothing
  lands on disk
- it answers **415**, a content refusal rather than a transport error

## So the gap is a misplacement, not a decision

`_page_parse_refusal` was written into `lazysite-mcp.pl` as a private sub, when
its sibling guard lives in `Lazysite::Manager::Common` with a WebDAV caller
already wired to it. **Nobody decided WebDAV should be exempt; the guard was put
in a file WebDAV cannot reach.** That is worth stating plainly rather than
dressed up as a design boundary.

## The one honest argument for divergence, and why it is weak

`raw_html_page_refusal` inspects a 16KB head, because front matter is at the
head. **A template parse failure can be anywhere in the body**, so this check
needs the whole thing - a real difference, and the only one.

It does not amount to much. The PUT path already streams to a temp file with a
size cap enforced during the write (`lazysite-dav.pl:597`), so "the whole body"
is bounded by construction; and the file is already on local disk at the point
the existing guard runs. The cost is one read of an already-capped, already-local
file, on a path that is already reading 16KB of it.

## The strongest case FOR exempting WebDAV, stated fairly

A sync tool writing many files may handle a per-file 415 badly - aborting, or
retry-looping - leaving a tree half-updated. A wrong page that renders is
arguably recoverable where a stuck sync is not.

**SM189 already accepted that risk** for raw HTML pages, so accepting it here is
consistent rather than novel. If the risk is now judged unacceptable, that is an
argument for revisiting SM189 too, not for leaving one guard on one stack.

# Recommendation

Move the check to `Lazysite::Manager::Common`, beside
`raw_html_page_refusal`, and call it from the DAV PUT path the same way -
bounded read of the temp file, refuse before the rename, 415.

**That is not new design. It is finishing a pattern this codebase already
chose**, and it is the shape SM430 argues for generally: one answer per
operation, wherever the operation is invoked.

