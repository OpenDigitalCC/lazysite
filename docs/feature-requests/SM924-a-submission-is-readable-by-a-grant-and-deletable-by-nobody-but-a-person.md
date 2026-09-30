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
status-note: "RULED 2026-09-30, NOT BUILT - and this filing's own recommendation was measured FALSE first. IT SAID `the row already records enough to know` who created a submission. IT DOES NOT. A stored row carries the visible fields plus `_submitted`, `_ip`, `_form` and the quarantine flags (Handlers.pm:1341-1356); `_source` is set ONLY when the origin is not `form`. There is no actor, and that is deliberate: form-handler.pl:153-163 records a public submission as having NO verified actor, because `_auth_user` was forgeable, was dead in every delivery target anyway, and a forged name had been reaching the ACTOR COLUMN of the shared audit trail - a false record in the one artefact whose purpose is to say who did something. And `_ip`, which that comment calls the fact that IS known, is per [[SM929]] the front proxy's address, identical on every row of every site behind it. So nothing on a submission row distinguishes who made it, and `delete rows the caller created` has nothing to key on. RULING, re-asked on that measurement: A SEPARATE CAPABILITY, OFF BY DEFAULT. It gates on the grant rather than on provenance, so it needs no attribution and works today. IT MUST BE NAMED FOR WHAT IT PERMITS - deleting any submission on the site, not `delete your own test data` - and the docs must say so, because an operator who grants it on the softer reading has granted the harder thing. Declined: making the origin attributable first (materially more work, and testing the real public form would STILL leave an unattributable row unless a test mode were added too); and ruling it out (the litter is the reported problem). NOT AFFECTED: N14-03's row-ownership shape for `write_data` stands - a data-table write comes from an authenticated caller, a form submission does not, and conflating the two is what produced this filing's wrong recommendation."
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
2. **Delete confined to rows the caller created.** ~~The row already records enough
   to know~~, and this is exactly the shape N14-03 records for `write_data` ("row
   ownership: write_data confined to rows the caller created") - so it would be the
   second use of one idea rather than a new one. An agent can clear its own test
   row and nothing else.

   **STRUCK THROUGH 2026-09-30: THE PREMISE IS FALSE, and it was mine.** A stored
   row carries the visible fields plus `_submitted`, `_ip`, `_form` and the
   quarantine flags (`Handlers.pm:1341-1356`). No actor. `_source` is written only
   when the origin is NOT `form`, so a submission through the form - the case this
   filing is about - records nothing about who sent it.

   That is not an oversight to be repaired. `form-handler.pl:153-163` says a public
   submission is recorded as having no verified actor on purpose: `_auth_user` was
   forgeable, it was dead in every delivery target anyway, and the forged name was
   reaching the **actor column of the shared audit trail** - a false record in the
   one artefact whose whole purpose is to say who did something.

   And the fact that comment offers as the one thing genuinely known - the address -
   is per [[SM929]], filed the following day, the front proxy's address, identical
   on every row of every site behind it.

   So there is nothing to key ownership on, and there was never going to be. The
   error was reasoning from `write_data` to a form submission: a data-table write
   arrives from an authenticated caller and a form submission arrives from a
   visitor, so N14-03's shape does not transfer. N14-03 itself is unaffected.
3. **Rule it out and say so.** An agent testing a form leaves a row behind, an
   operator clears it, and the briefing tells agents to expect that. Cheapest, and
   it makes every agent's form test leave litter a person must sweep.

~~(2) is the one worth costing first, because the mechanism is already wanted
elsewhere and a capability that means "delete your own test data" is much easier
to grant than one that means "delete submissions".~~

## Ruled 2026-09-30: a separate capability, and it is named for what it permits

(2) was chosen first and then withdrawn on the measurement above - it cannot be
built, because there is no creator on the row and deliberately never will be.

**RULED: a separate capability, off by default.** It gates on the grant rather than
on provenance, so it needs no attribution and works against the store as it stands.

**The condition attached to it is not decoration.** It permits deleting **any
submission on the site**, and it must be named and documented as that. The reason
this filing recommended (2) was that "delete your own test data" is easier to grant
than "delete submissions" - and that remains true, which is exactly why a
capability that does the second must not be described as the first. An operator who
grants it on the softer reading has granted the harder thing to an agent.

Declined: **making the origin attributable first** - materially more work, and it
would not even solve the reported case, because an agent testing the real public
form would still leave an unattributable row unless a test mode were added on top.
And **ruling it out** - the litter a person must sweep is the problem that was
reported, so answering it with "expect litter" answers nothing.

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
