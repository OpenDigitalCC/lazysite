---
title: "SM647: `domain-set` writes the domain access model and publishes `changes_access: false`, so the one flag a caller can consult is wrong about it"
subtitle: "Site agent, 2026-08-26, closing the object-scoping question R-10 left open - by source review, because the honest instrument would have been a live grant-widening write"
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED. domain-set joins %CHANGES_ACCESS on the control API and gains the fourth annotation slot on MCP, so both channels say it moves the read boundary - which it does, by writing allowed_groups. t/lint/23's twin check passes. DONE IN ONE PASS WITH SM649, which is the same table read in the opposite direction: over-flagging preview-grant pointed a reviewer at a door that was not there and spent the credibility of the flag, which is part of why this omission was easy to miss. THE SCOPE-GUARD HALF REMAINS OPEN and unproved, exactly as the site agent left it: proving it needs a live grant-widening write, which they correctly declined to run on a shared instance. That half is unchanged by this commit and its evidence requirement is recorded in the body."
---

# The measured half

Read from the live instance via `actions-list` on build 0.10.34, and confirmed
in the source on main:

| Action | `changes_access` published | Writes an access decision? |
|---|---|---|
| `acl-set` | true | yes - a path rule |
| `acl-remove` | true | yes - a path rule |
| `preview-grant` | true | yes - a preview grant |
| **`domain-set`** | **absent (falsy)** | **yes - `allowed_groups`** |

    my %CHANGES_ACCESS = map { $_ => 1 } qw(
        acl-set acl-remove
        preview-grant preview-clear
    );

`allowed_groups` is what decides which groups reach a domain's content. An
action that writes it changes access by any definition the other three entries
satisfy.

# Why a wrong flag is worse than no flag

`changes_access` exists so a caller - a reviewing agent, an operator's
tooling, a future gate - can ask "does this need a second look?" without
knowing what every action does. A missing entry does not read as "unknown"; it
reads as "no". So the one action in this group that reaches the domain access
model is the one that answers reassuringly.

Nothing else in the response distinguishes it. The action is correctly gated on
`manage_domains` and correctly listed as mutating; the flag is the only place
this fact was supposed to appear, and it is the place it is missing.

# The half that is NOT proved, and must not be read as though it were

The brief's §3 asks whether a write admitted by `manage_domains` can change
which objects a *different* capability's actions then reach - the object-scoping
question R-10 could not answer. R-10 established only that capabilities compose
by strict union for action REACHABILITY: which of the allowlisted actions the
gate admits. Reachability is not scope.

The agent answered by reading the shipped source and **marked the result
unverified**, because the honest instrument would have been a live write to a
real domain's `allowed_groups`. That is a grant-widening mutation, and running
one against a shared instance to satisfy a test is exactly what the standing
rule forbids - restore-on-exit or not. Declining it was correct.

So this filing carries a proved defect and an open question, and says which is
which. Whoever takes it should not assume the scope guard is absent because the
declaration is wrong; they are separate claims with separate evidence.

# What would settle the open half

A check the operator can run, from the brief's §5: a credential holding
`manage_domains` and NOT the capability whose objects are in question, then a
`domain-set` against a domain outside that credential's scope. If it is
refused, the guard exists. If it succeeds, the composite path is real and the
severity of this filing changes.

That needs a grant the agent could not mint for itself, which is why it is
named here as work for someone who can rather than left as a doubt.

# The fix

Add `domain-set` to `%CHANGES_ACCESS`. One line, and it makes the published
declaration true.

Then answer the scope question separately, with the credential above, and
record the answer here - including if the answer is "the guard is already
there", because a proved negative is what stops this being re-opened.
