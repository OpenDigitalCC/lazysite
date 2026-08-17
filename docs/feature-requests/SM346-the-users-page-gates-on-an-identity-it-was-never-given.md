---
title: "SM346 - the Users page hid every operator-only control from every human"
subtitle: "It decides what to show by looking for itself in the groups that grant manage_users. The payload never told it who it was, so it never found itself, and the answer was no for everybody - including a full operator."
brand: plain
status: shipped
status-note: "FILED AND FIXED 2026-08-17. Reported as \"a human sub-user of a manager has no promote-to-top-level menu option, whereas AI agents do\", which is a narrower statement than the defect: NO human saw it, operator or not. Agents were never subject to the gate because they drive the control API and MCP, which have no UI. Nothing was ever wrongly permitted - the API enforced correctly throughout - a capability was wrongly WITHHELD, and silently, because an absent control produces no error to read."
---

# What was found

The Users page gates its operator-only controls on `amOperator`:

```javascript
if (ME && info.caps && info.caps.manage_users && members.indexOf(ME) !== -1) {
  amOperator = true;
}
```

`ME` comes from `d.partner || d.me` on the `users-page` response. **That response
carried neither.**

`users-page` is a consolidation of three earlier calls - its own comment says so:

> Was three separate CGI calls (users-detail + group-settings-get + whoami)

It brought forward the data of the first two and the identity of the third not at
all. So `ME` stayed empty, `amOperator` was false for every human, and the
controls it gates were invisible: promote-to-top-level, and the
scope-independence toggle beside it.

# Why it looked like a difference between humans and agents

An agent doing the same thing goes through the control API or MCP, where the
capability is checked and the operation allowed. There is no UI gate on that
path at all. So the same account-level operation worked for an agent and was
absent for a person, which reads as a permissions difference and is not one.

**And the failure is silent by construction.** A refused action returns an error
somebody can quote. A control that was never rendered produces nothing to read,
so the only way to notice is to know it should be there.

# Why the reported symptom understated it

The report said a sub-user of a manager. The condition is unconditional: the
username being searched for was the empty string, so no membership test could
ever match, so no human ever qualified - a full operator included.

Worth recording, because the narrower version has a plausible and wrong
explanation ("sub-users are meant to be restricted") which would have closed the
report without finding the bug.

# The fix

`users-page` reports `me`, and the manager API supplies it from the
authenticated caller for that action.

**A separate key from `actor`, deliberately.** `actor` carries authorisation
meaning in the users tool - the `ACTOR_FORBIDDEN` backstop refuses privileged
verbs when it names a non-operator - so reusing it to mean "who is asking" would
attach an authorisation signal to a read-only call. `me` is inert: it is
reported and nothing branches on it.

# Verification

- `users-page` reports the authenticated caller.
- The API supplies it for that action and sets no `actor` doing so.
- `ACTOR_FORBIDDEN` still confines every verb it was written for.
- An operator sees the promote-to-top-level option; a non-operator does not.
- The API continues to enforce the same rule regardless of what the UI shows.

# Related

[[SM194]] (which added the operator-only promote choice and the `amOperator`
gate), [[SM268]] H4 (a capability the control API enforced and MCP did not - the
same two-surfaces-disagreeing shape, pointed the other way), and
`starter/manager/users.md`.
