---
id: SM924
title: "SM924: a submission is readable by a partner grant and deletable by nobody but a person"
subtitle: "read_submissions publishes form-submissions and no counterpart. WebDAV refuses the submissions tree to every grant, correctly. So an agent that builds a form, tests it end to end and wants to clear its own test row has no route on any surface it can reach - and the alternative it is left with is asking a person to open the manager."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-29
raised-by: site agent, after testing a form it had just built
area: mcp
---

# The gap

`read_submissions` is a least-privilege READ grant, deliberately: SM652 settled
that reading a submission needs it on every channel, and that it does not permit
editing forms or handlers. The delete actions exist - `form-submission-delete` and
`form-submissions-delete-bulk` on the control API - and they are not reachable with
that grant. WebDAV refuses the submissions tree to every grant, which is right.

The result is that an agent which builds a form, submits a test row to prove the
handler delivers, and then wants to remove that row, has to ask a person to open
the manager and click Delete. The test row is the agent's own, created seconds
earlier, for the purpose of verifying its own work.

# Why it is not simply "grant delete"

A submission is a visitor's data. A grant that can delete it is a grant that can
destroy evidence of what a site received, so widening `read_submissions` to include
deletion would be wrong - it is the least-privilege read grant and its value is
that it is only that.

Three shapes, and they differ in what they concede:

1. **A separate capability** for submission deletion, off by default, which an
   operator grants to an agent they want doing end-to-end form work. Honest, and it
   is another capability in a list that is already long.
2. **Delete confined to rows the caller created.** The row already records enough
   to know, and this is exactly the shape N14-03 records for `write_data` ("row
   ownership: write_data confined to rows the caller created") - so it would be the
   second use of one idea rather than a new one. An agent can clear its own test
   row and nothing else.
3. **Rule it out and say so.** An agent testing a form leaves a row behind, an
   operator clears it, and the briefing tells agents to expect that. Cheapest, and
   it makes every agent's form test leave litter a person must sweep.

(2) is the one worth costing first, because the mechanism is already wanted
elsewhere and a capability that means "delete your own test data" is much easier
to grant than one that means "delete submissions".

# What this is not

Not a parity defect in SM239's sense. The control API and MCP agree here - neither
offers deletion to this grant - so nothing is inconsistent between channels. The
gap is in the capability set, not in one channel's coverage of it, which is why
this is a decision rather than a fix.

# Related

[[SM652]] (read_submissions on both channels, and what it deliberately excludes),
[[SM632]] (form-delete, the inverse of bind_form),
N14-03 (row ownership for write_data - the same confinement idea),
[[feedback_lazysite_manager_ui_only_actions]].
