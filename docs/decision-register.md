---
title: "lazysite - decision register"
subtitle: "What the engine is waiting on the release manager to decide, each with the question, the options and a recommendation. A question asked only in conversation is a question nobody can find again."
brand: plain
standard-margins: true
---

# Why a register

The same argument `docs/gate-register.md` and `docs/manual-check-register.md`
make, for decisions.

The engine agent regularly reaches a point where the next step is a judgement
that is not its to make - which release carries a breaking default, whether a
message is worth the thing it costs, who may write a destination. Those were
being asked in conversation, where they scroll away, and the release manager
had no list to read. This is that list.

**The filings are the source of truth.** Each row points at its SM, which
carries the reasoning, the evidence and what was already built. This register
carries only the question, so it can be read in a minute.

A row leaves when the decision is made: the SM records the ruling in its
`status-note`, and the row is deleted rather than marked answered - the
register is what is OPEN, not a history.

# Open

```datatable
columns: Item | The question | Recommendation
widths: 3cm | X | 6cm
bold: 1
tone: medium
---
[[SM786]] | Escape-by-default would escape a page that ALREADY escapes correctly - the learning catalogue uses `| html` on every column. Make the default idempotent with an explicit filter, or tell authors to remove theirs? | The reporter prefers removal, loudly, in the migration note, and is right that it is the more honest of the two: "already escaped" is not reliably detectable for arbitrary text. It asks the careful authors to change their pages, which is the cost.
[[SM816]] | The expander glyph renders as `+` beside a New connector button, so the only route to a row Save/Delete reads as "add another". Change the glyph to a rotating chevron, or surface a row's actions on the row? | Surface the actions on the row. It removes the ambiguity where it actually lives - the context, not the glyph - and `+`/`-` is a real disclosure convention across three stylesheets and four pages.
[[SM222]] | L2 "not routed" is the truly-off guarantee, and it couples a config toggle to a web-server reload - privileges the CGI does not have. Queue the change for a privileged helper, or accept "takes effect on next regeneration"? | Accept next-regeneration. A toggle that silently needs a privileged helper to take effect is the same class of lie as the switch it is fixing; saying when it applies is honest and needs no new privilege. OPEN since 2026-07-27 - the register found it, not a new question.
[[SM822]] | Nothing prunes the connector call record - 47 entries from connectors that no longer exist. Never prune, prune by age, or prune on delete? | **By age, with the window shown in the UI.** Pruning on delete makes the record erasable by the act it should be recording. Never-prune is defensible but leaves an unbounded store nobody can see the size of.
[[SM798]] | Should the login rate limiter be a plugin, so its dependency is checked before it is enabled? | **No** - see below. The dep check would guard a case that cannot happen and miss the one that does.
```

# The rate limiter as a plugin, answered

Asked 2026-09-09, and worth writing out because the reasoning generalises.

The mechanism is real: a plugin declares `owns.deps`, and `_missing_deps`
refuses to enable it while any are absent. So the shape of the idea works.

It does not help here, for a reason that only shows on inspection: **`DB_File`
is a core Perl module.** `debian/control` says so in as many words - "perl
covers the core modules (JSON::PP, Digest::SHA, DB_File, ...)" - so the branch
that fails open for a missing `DB_File` is guarding something that essentially
cannot occur on a supported host.

The branch that *can* fire is the other one: a counter that will not open -
permissions on `lazysite/auth/`, a full disk, a read-only tree. **A dependency
check cannot see any of those**, because they are facts about the site at the
moment of the request rather than about what is installed.

There is a second objection, which would stand even if the dependency were a
real risk. A plugin is **opt-in and disableable**, and a login rate limiter is
neither: making it a plugin would mean a site could turn off its own brute-force
protection, and the disabled state would look exactly like the failure this SM
exists to make visible.

**What gets the benefit without either problem** is the health check.
`lazysite-check` is where an operator looks for facts about their site, and a
line there - *the login rate limiter is not in force, and why* - catches the
permissions case, which is the one that happens. It is recorded as not-built in
SM798 and is a small change if the release manager wants it.

# How this register is kept

The engine agent adds a row when it reaches a decision that is not its to make,
and deletes the row when the decision arrives. It is committed with the change
that raised the question, so the question and its context land together.
