---
title: "SM233 - The 'Independent of creator' control does not say what it does"
subtitle: "A checkbox labelled with an adjective and a tooltip written in engine vocabulary. An operator cannot tell what the toggle governs, what turning it on would change, or whether it is already changing anything."
brand: plain
status: shipped
status-note: "IMPLEMENTED in the 0.10.2 edge line (2026-08-08, commit 97fd1a8). Reported by the operator 2026-08-07 from live use of the manager: 'really confusing - the information provides no clue as to what this does'. Copy and presentation only; the underlying SM194 behaviour is correct and unchanged."
---

# SM233 - the scope-independence control is unreadable

## Why

The account editor in `starter/manager/users.md` offers an operator-only
checkbox:

```
Scope    [ ] Independent of creator   (i)
```

with the tooltip:

> On: this account is not scope-capped by whoever created it (the created_by walk
> stops here). Off keeps the deliberate ceiling. created_by itself is never
> changed.

Neither tells an operator what the control provides.

**The label names a relationship, not an effect.** "Independent of creator"
invites every reading except the right one - independent for billing, for
ownership, for management, for deletion. The thing it actually governs, *content
access*, does not appear in the label at all.

**The tooltip is written in engine vocabulary.** "Scope-capped", "the created_by
walk stops here", "the deliberate ceiling" and "created_by itself is never
changed" are all internal terms. `created_by` is a settings key and the "walk" is
a loop in `resolve_user_scopes`; neither is visible to, or meaningful for, the
person reading the tooltip. The one genuinely useful fact - that this account
would then be able to reach content its creator cannot - is never stated.

**Two nearby controls both sound like independence.** The Parent row directly
above offers "top level (no parent)", and the promotion confirm has to explain
the difference by naming this checkbox:

> It does NOT lift the creator scope ceiling - use "Independent of creator" for
> that.

When one control's confirmation text exists to disambiguate it from another
control, the labels are colliding.

**The operator cannot see whether it matters.** Nothing shows what the current
ceiling is, who imposes it, or what the account can reach today. The toggle may
change everything or nothing, and there is no way to tell before flipping it.

## What the control actually does

Worth stating plainly, because the fix depends on saying it well.

An account's reachable content is normally limited to at most what the account
that created it can reach - and that limit follows the entire chain of creators,
not just the immediate one. It is resolved at request time, so later
configuration changes cannot lift it.

Turning this on stops the chain at this account: its access is then decided by
its own domain grants alone, and it may reach places its creator cannot. The
record of who created the account is never altered, because audit provenance
depends on it.

It is deliberately separate from moving an account to top level. Promotion clears
the managing parent; the access ceiling follows creation, not management.

## What to change

### The label

Name the thing it governs. Recommended:

```
Content access    [ ] Set by its own grants alone   (i)
                      Currently capped by: alice -> bob
```

The row label carries the subject ("Content access") and the checkbox carries the
effect. An alternative worth considering at review is inverting the sense -
"Limited by creator" checked by default - which makes the safe state the checked
one; it costs a UI-side inversion against the API value and should only be taken
if reviewers find it clearer.

### The tooltip

Plain language, the consequence first, no internal terms:

> Off: this account can reach at most what the account that created it can reach,
> and that limit follows the whole chain of creators. On: its access is decided by
> its own domain grants alone, so it may reach content its creator cannot. The
> record of who created it is unchanged either way. This is separate from the
> Parent setting above - moving an account to top level does not affect it.

### Show the current state

The most useful change, and the one that makes the toggle legible: display the
ceiling inline. Which ancestor is capping this account, and what the account can
reach as things stand. An operator can then see whether the toggle would change
anything before touching it, which no amount of tooltip rewriting achieves.

`resolve_user_scopes` already computes this; surfacing the chain it walked and
the resulting roots is a presentation change rather than new logic.

### Keep the vocabulary consistent

Every place naming this control must move together:

- the promotion confirm in `promoteUser`, which currently names "Independent of
  creator" to distinguish itself
- the status messages in `toggleScopeIndependent` ("now independent of its
  creator's scope" / "back under its creator's scope ceiling")
- `docs/FEATURES.md`, which describes the flag in three places

The stored key `scope_independent`, the control-API action
`account-scope-independent` and the CLI verb stay as they are. This is a
presentation fix and should not churn the interface contract.

## Verification

- The label states what the control governs without needing the tooltip.
- The tooltip contains no term that exists only in the source.
- The current ceiling is visible next to the control, including when there is
  none.
- Promotion and emancipation are distinguishable from their labels alone, without
  a confirmation dialog explaining the difference.
- The stored value, the API action and the CLI verb are unchanged, and the
  existing SM194 tests still pass untouched.

## Not in scope

- Any change to how the ceiling is resolved or enforced. SM194's behaviour is
  correct.
- Rewriting `created_by` under any circumstance.
- Making the control available to a delegate. It is operator-only and the API
  refuses a delegate regardless; that stays.
