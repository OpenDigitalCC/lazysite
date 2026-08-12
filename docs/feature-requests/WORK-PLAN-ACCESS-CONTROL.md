---
title: "Work plan - access control, made consistent and then written down"
subtitle: "Four filings, then surface parity, then the documentation that keeps it true. Written 12 August 2026 after two wrong answers in one session, both from trusting prose over code."
brand: plain
standard-margins: true
---

# Why this plan exists

In a single session the operator asked two reasonable questions about who can
see what, and got two wrong answers from me:

- *"the root `/` cannot be restricted as a folder?"* - correct, and written down
  nowhere ([[SM287]]);
- *"partners do have groups applied"* - correct, and the architecture document
  and a code comment both said the opposite ([[SM288]]).

Neither was a coding error. Both were **documentation that had drifted from the
code and was believed anyway** - one for three releases, one for about a year,
through an analysis, a security review and a feature built directly on top of
it.

So the goal is not only to finish the work. It is that the next person asking
these questions gets the right answer without reading `Lazysite::Auth::Acl`.

# The decision taken

**Consistency, not reconciliation.** Operator's call, 12 August 2026.

lazysite keeps its two mechanisms and makes them agree:

`acls.json`
: who may **read or write a path** - a file, a folder, or (after SM287) the
  whole site.

`auth:` / `groups:` / `auth_default`
: who may **read a page**.

What that buys is a small, well-understood change with no compatibility event.
What it explicitly does **not** do is fold them into one store - SM224's
deferred recommendation. That remains deferred, is not part of this plan, and if
it is ever taken it needs its own ADR and a migration, because ADR 0008's
stable-compatibility freeze applies to both surfaces.

The documentation must therefore do a job it has never done: state that there
are two mechanisms, say plainly **which question each answers**, and be honest
that the split is a decision rather than an accident.

# Phase 1 - the dev items, in this order

```datatable
columns: # | Filing | Why here
widths: 1cm | 3.2cm | X
bold: 2
text: 3
tone: medium
---
1 | [[SM285]] | The self-probe. First because it verifies every item after it from the OUTSIDE, on any front end, and because it is the only thing that can tell an operator whether a deployment we cannot see is exposed while the rest is in flight. Small.
2 | [[SM288]] | One group resolver on every channel. Makes the SUBJECT model uniform - a group becomes a property of the account rather than of the door it arrived through. Small, and it is the defect the operator found.
3 | [[SM287]] | The root scope. Makes the SCOPE model complete - file, folder, site. Small, independent of 2.
4 | [[SM286]] step 1 | Gated content moves out of the document root. Makes the model ENFORCEABLE whatever is in front of it, which is the difference between "protected" and "protected if the vhost is right". Large, and last because the three above are cheap and it is not.
```

Items 2 and 3 are independent of each other and can land in either order or
together. Item 4 is the one that changes where bytes live, so it wants the probe
(item 1) already in place.

**SM288 widens access on upgrade.** An `@group` entry that has been silently
inert for MCP partners starts applying. That is the intended behaviour and it is
still a change of effective permissions on live sites: it needs its own heading
in the release note, not a bullet, and `lazysite-check` should report beforehand
which entries would begin matching which partners.

# Phase 2 - the same method from every surface

The gaps, found by looking rather than assuming:

**The CLI cannot set access at all.** An operator on the box can create users
and groups with `lazysite-users.pl` and has no verb for granting access to a
path. Manager, control API and MCP can; the CLI cannot; WebDAV enforces without
setting. For a product whose recovery story is "you have a shell", that is the
sharpest gap of the three.

**Two names for one operation.** `acl-set` / `acl-get` / `acl-remove` on the
control API, `set_permissions` / `get_permissions` over MCP. One vocabulary,
whichever is chosen, and the other kept as an alias if compatibility requires -
ADR 0008 governs.

**One superseded recommendation to retire.** SM224 proposed renaming
`set_permissions` to `set_authoring_access`, on the grounds that it governed the
four authoring channels *and not the public one*. **SM223 made that false** - the
ACL now governs the anonymous read path too. The name is more accurate today
than when the criticism was written, and the rename should be formally dropped
rather than left sitting in a document as an open suggestion.

Parity means the same scope grammar (file / folder / root), the same subject
grammar (user, `@group`, owner), and the same two policies (gated / draft)
everywhere - so an operator who learns it in the manager can use it over MCP
without re-learning it.

# Phase 3 - the documentation, and the guard that keeps it true

## What to write

`docs/architecture/access-control-model.md`
: currently an **analysis** (SM224) with corrections bolted on, and it is the
  document that gave the wrong answer. It should become the **reference**: the
  two mechanisms, which question each answers, the scope grammar, the subject
  grammar, the two policies, and the per-channel table. The historical analysis
  moves to an appendix or its own file - it is worth keeping, but a reader
  looking for "how does this work" must not land in an argument about what it
  should have been.

`docs/FEATURES.md`
: Part III documents authorization as **authoring** permissions. It needs the
  visitor-facing half: that a site can limit who sees a page, a file, a folder
  or the whole site; that the ways are `auth:`/`groups:`/`auth_default` for
  pages and `acls.json` for paths; that gated bounces to login while draft
  returns 404 and leaves the sitemap, feeds and search; and that protection is
  opt-in, so an unmentioned file stays public.

`docs/manager-ui-guide/`
: the Protect-this-section walkthrough, with its Negative row - already
  lint-enforced for menu-completeness by `t/lint/32`.

## The guard - the part that makes this different from last time

Writing it down is what we did last time. It rotted, and it was believed while
rotten. **Anything in these documents that states a fact about the code must be
pinned by a lint**, in the manner of `t/lint/31` (the processor's ACL copy
matches the shared one) and `t/lint/32` (the guide covers the nav):

- the **per-channel group-resolution table** is asserted against the actual
  assignments in `lazysite-dav.pl`, `lazysite-mcp.pl` and
  `lazysite-manager-api.pl` - the exact drift that produced SM288;
- the **scope grammar** is asserted against what `_acl_entry_for` resolves, so a
  scope documented but unreachable (SM287's root) fails the build;
- the **policy table** is asserted against the processor's draft/gated
  behaviour;
- any surface gaining or losing an ACL verb fails the parity lint.

A comment is not a guard. The comment that caused SM288 sat directly above the
variable it described and was wrong about the channel that mattered.

# Sequencing, and the one risk worth naming

Docs follow the dev work, because documenting a model that is about to change
means writing it twice. The risk in that order is obvious: if item 4 slips, the
documentation waits behind it and the session that needed it has already gone.

**So phase 3 does not wait for all of phase 1.** Write the reference as soon as
items 1-3 land - at that point the scope grammar, the subject grammar and the
policies are all settled, and item 4 changes only *where the bytes live*, which
is one paragraph in the reference and no change at all to the model a user sees.

# Not in scope

- Reconciling the two mechanisms into one store (SM224's recommendation) -
  deferred by decision, needs its own ADR.
- Renaming `set_permissions` - the reason for it no longer holds; see phase 2.
- SM286 steps 2-5 (moving `lazysite/` out of the docroot, registries, the trust
  strip, the daemon shape). They continue on their own filing; only step 1 is
  part of this plan, because only step 1 changes access control.

# Related

[[SM285]], [[SM286]], [[SM287]], [[SM288]], [[SM224]] (the analysis, and the
source of the superseded rename), [[SM223]], [[SM283]] (why enforceability and
documentation are the same problem), ADR 0001, ADR 0008.
