---
title: "SM258 - A shipped item stays open in the backlog, and no test notices"
subtitle: "The CHANGELOG names the SM numbers each release carried. Nothing compares that against the docs' own status headers, so an item can ship, deploy, and go on reporting itself as open work."
brand: plain
status: candidate
status-note: "Filed 2026-08-08 after correcting the SAME drift twice in one session: 25 items at the 0.10.2 cut, then 10 more at 0.10.3 - four of which were among the 25 and had drifted straight back. The existing lint (t/lint/09-feature-request-status.t) cannot catch this by construction: it checks a status against its own status-note, so an item whose note never mentioned shipping is internally consistent while being wrong. Deliberately NOT written alongside the correction it polices - a lint authored in the same breath as its fix tends to be shaped to pass."
---

# SM258 - the backlog drifts from the CHANGELOG

## Why

Every release CHANGELOG entry names the SM numbers it carried:

```
- SM238 (37e7c37) per-domain tools over MCP: ...
- SM239 (0dd587f) MCP/control-API action parity, enforced: ...
```

Every feature-request doc declares its own status:

```yaml
status: candidate | shipped | partial | parked | superseded
```

Nothing compares the two. So an item is released, tagged, packaged and deployed
while its doc still says `candidate`, and every reader of the backlog - the
operator planning a release, an agent asked what is outstanding, `tools/backlog.pl` -
is told it is open work.

Marking the doc is a manual step at the end of a release, competing for attention
with the gate, the tag and the build. Nothing fails when it is skipped, so it is
skipped, and the backlog silently inflates.

## The existing lint cannot catch it

`t/lint/09-feature-request-status.t` enforces that a status header exists and
that non-terminal states explain themselves. It reads each doc in isolation. An
item that shipped, whose `status: candidate` and whose `status-note` describes
the problem and never mentions a release, is perfectly self-consistent - and
wrong. Internal consistency is the wrong axis; the CHANGELOG is the external
fact.

## Evidence

Twice in one session, on the same backlog:

- **0.10.2 cut**: 25 items marked open while their own notes recorded them as
  shipped. Open items dropped from 40 to 24.
- **0.10.3 cut**: 10 more - SM235, SM237, SM238, SM239, SM240, SM241, SM242,
  SM243, SM244, SM255. **Four of them (SM235, SM237, SM241, SM242) were part of
  the 25 corrected a release earlier and had drifted straight back**, because the
  0.10.2 correction fixed the data and not the mechanism.

That last detail is the argument for a test rather than more care.

## What to do

A lint that reads the CHANGELOG, extracts every `SM\d+` mentioned under a
released version heading, and requires each one's doc to be in a terminal state
(`shipped`, `partial` or `superseded` - `partial` is legitimate for an item that
shipped in stages, `candidate` never is).

Points to get right:

- **Only released headings count.** An SM named in an unreleased section, or in
  prose about future work, must not flip anything.
- **`partial` needs its note to say what remains**, which the existing lint
  already enforces - so the two compose rather than overlap.
- **The failure message must name the release and the commit** from the CHANGELOG
  line, since that is exactly what the correction needs to write into the note.
- **Read the CHANGELOG as data, not by eye.** It is the file the release process
  already maintains carefully, which is why it is the right source of truth here.

Consider also the reverse direction: a doc marked `shipped` that no released
CHANGELOG entry mentions. That is the weaker check of the two (an item can ship
inside another SM's work) and should probably warn rather than fail, if it is
included at all.

## Tests

The lint is itself the test. It should fail today against a deliberately
regressed fixture - take a shipped item, set it back to `candidate`, confirm the
lint names the release that carried it.

## Scope

New `t/lint/` file. No production change. Related: SM254 (engine docs drift) is
the same class of problem - a document that stops matching the system it
describes, with nothing watching.
