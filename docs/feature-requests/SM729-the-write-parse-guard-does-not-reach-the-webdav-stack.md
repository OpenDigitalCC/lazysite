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

# What needs deciding, not building

The agent's own question, and it is the right one: **is the WebDAV gap
intended?**

If the parse guard is deliberately manager/MCP-only - because WebDAV is a file
transport that does not know what a page is - then that is a defensible position
and the filing becomes one line of documentation, saving the next tester the
same probe.

If it is not intended, the question is where the guard belongs. Putting it in
the WebDAV PUT path is one answer; moving it to whatever both stacks share is
the better one, and is the shape SM430 is about.

**Not decided here.** The measurement is the contribution.

# Still not proved

That the guard DOES fire on the manager/MCP path against a real site. The
content-save path is cookie-session only for the manager, and MCP was down for
the session. `t/unit/manager/140` proves it in the unit tier; nothing has proved
it in the field.
