---
id: SM815
title: "SM815: a place to say something and be answered, shipped with every site"
subtitle: "Three gated builds have each grown the same thing by hand - a private place where people ask plain questions and report problems. Specified as a shipped component, with one rule that outranks every feature in it: a person with a problem must be able to describe it in one box and press one button. Filed as a discussion, not scheduled, and its open questions are recorded rather than answered because the specification itself says to observe first."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-09
raised-by: sites agent
area: components
---

# The proposal

> A place to say something and be answered, which happens to keep a record -
> not a queue that happens to allow conversation.

Three gated builds have each grown a private working area and each grew a place
for people to talk. The report specifies that as a shipped component rather than
a thing every build reinvents.

# The rule it leads with, which is the part worth keeping

> A person with a problem must be able to describe it in one box and press one
> button.

The argument: every field beyond that is a tax, and it falls hardest on the
person least able to pay it - the one who does not know whether their thing is a
bug or a question, whether it is urgent, or which area it belongs to. **A form
that asks them to decide before they may speak has asked them to do the triage
that the system exists to do.**

It is offered as an observation rather than a preference, from two failures this
month: the Family HQ `qa` table framed as *questions for one named person*, so
everything that was not that had nowhere to go; and a public evaluation form
that opened with three paragraphs above the first field, which read as a wall of
prerequisites until the text moved into an expander beside the question it
explained.

The concrete tests it sets itself are the useful part, because they are
checkable: two inputs and nothing else required to post; no field asking for a
priority, severity, queue, type or assignee; the word "ticket" nowhere in the
interface; an empty state that says something a person would say rather than
"0 open tickets"; nothing on the ordinary path more than one click from the list.

# Why this is filed rather than scheduled

It is a component-sized proposal - a data model, a UI, notifications, and a set
of adjacent components it suggests shipping alongside - and it arrives as a
discussion. Nothing about it is urgent, and its own reasoning says to observe
before answering the questions it leaves open:

- Who may read a conversation. Everyone signed in is the simplest start.
- Whether a conversation may be deleted, or only closed.
- Whether an agent's reply should look different from a person's.
- Anonymous posting, which is a safety requirement in some organisations and
  immediately abused in others.

**Those are the right questions to leave open and the wrong ones to guess at**,
and the release manager should decide whether this is a 0.14 conversation before
any of it is designed further.

# What it needs first

It assumes a private area to live in, which is [[SM814]], which in turn depends
on [[SM813]]. If the intranet lands on a subdomain then this is table-backed
content on that domain and avoids the scan limitation the folder approach
carries. So the order is settled even though the schedule is not.

# Provenance

`inbox/2026-09-09-discuss-an-intranet-every-site-ships-with.md`, 290 lines,
read in full. Nothing in it was verified against the source because nothing in
it is a claim about the engine's present behaviour - it is a specification.

# A use case from the release manager, 2026-09-10

Recorded while ruling on [[SM811]], and worth keeping because it is a concrete
need rather than a hypothetical: **sharing development-context files between
people transversely, outside the project code.**

The occasion was `CLAUDE.md` - a file that governs how work happens, which must
not go to a public repo, and which therefore has no history, no review and no
way to share its state across projects or people. The release manager's framing
was that lazysite could carry an AI intranet for exactly this, and that local
state tracking across projects is the other half of it.

Two things this adds to the specification above:

- **A reader who is not a person.** The Discuss component is specified around
  people asking and being answered. This use case is a file an agent reads at the
  start of every session, shared between people and agents, which is a different
  access pattern: read-mostly, versioned, and consulted by machinery rather than
  browsed.
- **Outside the project code is the point.** The reason `CLAUDE.md` cannot be
  tracked is that the repo is public. Anything solving this has to live where the
  repo does not - which is the same boundary the intranet already needs for
  [[SM814]], and an argument that the two are one component rather than two.

Explicitly for another day, in the release manager's words. Not scheduled.
