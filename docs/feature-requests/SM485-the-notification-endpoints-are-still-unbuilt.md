---
title: "SM485: the notification endpoints are decided and unbuilt"
subtitle: "SM281 answered the addressing question and shipped that answer. The three pieces of work it unblocked have not been started, and were being carried on a filing whose status said otherwise"
brand: plain
standard-margins: true
status: candidate
status-note: "CARVED OUT OF SM281 ON 2026-08-23. SM281's own content was the ADDRESSING DECISION, the last of SM231's two open questions, and it went out with the 0.10.14 cut. What it explicitly did not do is the work that decision unblocks, and its note said so twice: 'the decision unblocks the work, it is not the work'. Carrying both on one filing produced a status nobody could set correctly: marking it done hides three unbuilt pieces, `candidate` denies a released decision, and `partial` is a state that never resolves. THE DECISION, RESTATED SO THIS FILING STANDS ALONE: a notice gains an optional `to` naming an account or a group; a notice WITHOUT one stays broadcast exactly as today, so nothing that emits a notice now has to change. That closes the per-user delivery gap Notify.pm has flagged since SM136. THREE PIECES, SIZED WHEN THE DECISION LANDED: the SMTP endpoint (S), the notice-store read surface (M, and an SM239 parity item in its own right), and the `to` field itself, which touches both. NOT INCLUDED, and deliberately: the agent-messaging door SM231 declined to build. That was a decision, not an omission, and it stays declined until somebody argues otherwise."
---

# What shipped, and what did not

```datatable
columns: Piece | State
widths: 7cm | X
bold: 1
tone: medium
---
The addressing decision (`to`, optional, broadcast when absent) | **done**, with the 0.10.14 cut -- see SM281
The SMTP endpoint | not started -- **S**
The notice-store read surface | not started -- **M**, and an SM239 parity item
The `to` field itself | not started -- touches both of the above
Agent messaging | **declined** by SM231, and still declined
```

# Why it is a separate filing

SM281 was marked `partial`, which is a status that never resolves: its own
subject is finished and the work it unblocked is untouched. A reader checking
whether notifications were delivered got a filing that said *some of it* -- and
the some that shipped was a paragraph of reasoning, not an endpoint.

Splitting it costs one number. It buys a filing that can be closed when the
endpoints exist, and a decision that is recorded as done because it is.

# The decision, so this stands alone

A notice may carry an optional `to` naming an account or a group. A notice
without one is broadcast, exactly as today -- backward-compatible by
construction, so nothing that emits a notice now has to change.
