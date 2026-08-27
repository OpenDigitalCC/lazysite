---
title: "SM289 - One way to express access, on every surface"
subtitle: "Manager, control API and MCP can each set an ACL, with two different vocabularies. The CLI cannot set one at all - on the product whose recovery story is a shell."
brand: plain
status: shipped
status-note: "FILED 2026-08-12 as phase 2 of WORK-PLAN-ACCESS-CONTROL, on the operator's direction to have standard methods from all surfaces. SHIPPED 2026-08-13 on main (unreleased). Gap 1 CLOSED: tools/lazysite-acl.pl + the `lazysite acl` verb (list/show/set/remove), calling the SAME action_acl_set the manager, control API and MCP call - so a rule set from a shell is the same object and gets the SM286 move too. --actor is MANDATORY for a write and gets exactly the authority that account has in the manager; verified by making the tool treat every caller as `local` and confirming the escalation subtest fails. Gap 2 RESOLVED AS DOCUMENTED, NOT RENAMED: acl-set and set_permissions are both in live partner use, and renaming either to settle a naming preference would break working integrations for no behavioural gain - the mapping is now a table in the reference. Gap 3 was already closed by SM290."
---

# SM289 - the same method from every surface

## Where access can be set today

| Surface | Verb | Can set an ACL? |
|---|---|---|
| Manager UI | Protect this section / the per-file editor | yes |
| Control API | `acl-set` / `acl-get` / `acl-remove` | yes |
| MCP | `set_permissions` / `get_permissions` | yes |
| WebDAV | - | enforces, never sets |
| **CLI** | **none** | **no** |

## The three gaps

**1. The CLI cannot set access at all.** An operator with a shell can create
users and groups (`lazysite-users.pl`), set channels and policies, run the
health check and repair permissions - and has no way to grant a person access to
a path. Every other administrative act on this product has a CLI form, because
the recovery story is "you have a shell". This one does not, which means the
answer to *"the manager is locked out and I need to grant myself access"* is to
hand-edit `acls.json` - the exact thing SM267 was built to stop people doing.

**2. Two names for one operation.** `acl-set` on the control API,
`set_permissions` over MCP. Same store, same effect, two vocabularies to learn.
Pick one; keep the other as an alias if ADR 0008 requires it.

**3. A superseded rename still sitting in a document as a suggestion.** SM224
proposed renaming `set_permissions` to `set_authoring_access`, because it
governed the four authoring channels *and not the public read path*. **SM223
made that false.** The ACL governs anonymous reads now, so the name is more
accurate today than the criticism of it. Retire the suggestion explicitly rather
than leaving a reader to act on it.

## What to build

A CLI verb with the same grammar as every other surface - the scope grammar
(file / folder / root), the subject grammar (user, `@group`, owner), and the two
policies (gated / draft):

```
lazysite acl list   --docroot D
lazysite acl show   --docroot D PATH
lazysite acl set    --docroot D PATH --read alice,@editors [--write ...] [--draft]
lazysite acl remove --docroot D PATH
```

It writes through the same writer the manager and MCP use - one writer, so a
section set from a shell and a section set from the panel are the same object
governed by the same rules. That is the property SM267 established when it made
the folder card use the per-file `acl-set`, and it is the reason this is a small
change rather than a fourth implementation.

Then one vocabulary across the API surfaces, and the SM224 rename formally
dropped.

## Care needed

**The CLI runs as whoever invoked it, and root is a plausible caller.** Every
other surface resolves an authenticated identity and applies the grant ceiling;
a CLI verb must not become the way to write an ACL that the manager would have
refused. Either resolve an actor (`--actor`, as `lazysite-users.pl` already does
for audit) and apply the same authority checks, or refuse to run without one.
Getting this wrong turns a convenience into a privilege-escalation path on the
one surface with no session behind it.

**Audit it.** ACL writes are material events on every other channel.

## Acceptance

- The same scope, subject and policy grammar is accepted by all four setting
  surfaces, and a rule written on one is read identically by the others.
- The CLI verb refuses to write a rule the same actor would be refused in the
  manager.
- Every CLI ACL write appears in the audit log with its actor.
- The two API names are reconciled, with any alias documented as an alias.
- SM224's rename recommendation is marked superseded in that document.

## Related

`WORK-PLAN-ACCESS-CONTROL.md` (phase 2), [[SM287]] and [[SM288]] (the grammar
this makes uniform - land those first), [[SM267]] (one writer for a section and
a file), [[SM224]] (the superseded rename), [[SM223]] (which made it
superseded), ADR 0008.
