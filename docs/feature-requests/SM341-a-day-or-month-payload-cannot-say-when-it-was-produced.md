---
title: "SM341 - a day or month payload cannot say when it was produced"
subtitle: "The index carries `generated`. The single-day and single-month responses carry nothing, so a reader comparing one against an earlier copy has to rely on their own notes for when either was made."
brand: plain
status: candidate
status-note: "FILED 2026-08-16 from a partner-agent observation made while staging a before-and-after capture across the 0.10.12 upgrade. Explicitly offered as an observation rather than a request, and explicitly not for that release - recorded because it is cheap, because the case that prompted it recurs whenever anyone compares a store across a change, and because [[SM340]] guarantees more of that comparing is coming. Small enough that it should travel with the next change to these payloads rather than justify its own."
---

# What was found

`index.json` carries `generated`, an ISO timestamp. The single-day and
single-month responses carry no such field.

So an agent holding a day rollup from before an upgrade and one from after can
say what changed, but can only say *when* each was produced from its own notes.
The artefact is not self-evidencing.

# Why it is worth a line

The comparison it blocks is not exotic. It is what anyone does when a release
changes how a number is computed - which [[SM329]] just did, [[SM339]] proposes
doing deliberately, and [[SM340]] causes to happen accidentally on every call.

The partner agent hit it while staging exactly that capture, and was careful to
note that it does not weaken their matched pair: the day file is the invariant
half and byte-identity is the test. That is right. What it costs is the ability
to reconstruct the comparison later from the payloads alone, without the notes
of whoever ran it.

An artefact that records when it was made survives its author's context. One
that does not is only as good as the message that accompanied it.

# What it is not

**Not a provenance mechanism.** `generated` on the index is a timestamp, not a
signature, and this would be the same. It answers "when was this produced",
which is the question actually being asked, and nothing about authenticity.

**Not a reason to touch these payloads on its own.** It should travel with the
next change that opens them - most plausibly [[SM339]], which rewrites day files
anyway and would want to record when it did.

# Verification

- A single-day response says when it was produced.
- A single-month response does the same.
- The field matches the index's existing `generated` in name and format, so a
  reader does not have to learn two conventions.
- A day file already on disk is not rewritten merely to acquire one.

# Related

[[SM340]] (which makes cross-upgrade comparison routine rather than occasional),
[[SM339]] (the release that would naturally carry this), [[SM338]] (the
comparison that prompted it), and [[SM213]] (the durable store's shape).
