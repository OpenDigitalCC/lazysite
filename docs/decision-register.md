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
[[SM816]] | The glyph is fixed. What remains: should a listing row surface its own actions, or keep management one level down behind the disclosure? | Not connectors alone - `.mg-row` is shared by four pages and the style guide, and a one-page fix to a shared-idiom complaint is the defect SM806 and SM816 both are. It is a design pass across every listing, and it carries a real trade: Delete on every row is destructive one click from a list.
[[SM222]] | L2 "not routed" is the truly-off guarantee, and it couples a config toggle to a web-server reload - privileges the CGI does not have. Queue the change for a privileged helper, or accept "takes effect on next regeneration"? | Accept next-regeneration. A toggle that silently needs a privileged helper to take effect is the same class of lie as the switch it is fixing; saying when it applies is honest and needs no new privilege. OPEN since 2026-07-27 - the register found it, not a new question.
[[SM824]] | Rec 3 of the knowledge-standards survey - package the build method as an Agent Skill - was neither accepted nor held when the other three were ruled. Accept, hold, or decline? | HOLD, on the survey's own sequencing: it is last of four and the most speculative, and the two accepted items should be measured before a skill is written to wrap them.
[[SM798]] | Added to the extensions batch. The recorded answer was NO - a rate limiter must not be disableable - and the batch resolves that rather than overruling it: audit, content history and the rate limiter all need an extension whose ENABLEMENT CARRIES A CONSTRAINT. Confirm that is the mechanism to build? | Yes. Three filings ask for it from different directions, and without it none of the three can be an extension at all. The rate limiter then becomes one that reports itself and cannot be switched off.
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
