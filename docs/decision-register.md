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
[[SM816]] | A listing row hides its management behind a disclosure. Should the row carry its own actions instead? It is a design pass across four pages, the style guide and three stylesheets - not connectors alone - and it puts Delete one click from a list. | Detail requested 2026-09-10; see the filing, which now sets out what the row looks like today, what would change, and the three sub-questions (which actions, which lists, and what happens to the disclosure).
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
