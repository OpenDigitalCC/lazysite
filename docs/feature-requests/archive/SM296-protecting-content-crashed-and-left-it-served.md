---
title: "SM296 - Protecting content crashed, and left the content served"
subtitle: "On 0.10.8, setting a permission on any path that held content returned Tool error or HTTP 500. The rule was stored and honoured; the content stayed in the document root. One line, and it was the mechanism built to make that impossible."
brand: plain
status: shipped
status-note: "REPORTED 2026-08-13 by a site agent on a 0.10.8 host, measured from outside over both partner surfaces. FIXED 2026-08-14 on claude/sm296-acl-set-crash: File::Path::make_path CROAKS, so the guard on the following line was unreachable and the die went out through action_acl_set. Two commits - the crash fix, then a lazysite-check that reports whether the store is usable at all. LIVE ON 0.10.8 EDGE until this ships; the affected state is a stored rule with the content still served, which is SM283's shape."
---

# SM296 - the mechanism failed into the thing it prevents

## What was measured

From a site agent, over MCP and the control API. The reporting host is not
named here on purpose: the first attribution was wrong, and the finding does not
depend on it. Only a 0.10.8 site can reach this code at all, which is the only
thing about the host that matters.

> Setting a permission on any path that holds content fails on 0.10.8, on both
> partner surfaces. MCP `set_permissions` returns `-32603 Tool error`; the
> control API `acl-set` returns HTTP 500. A path with no content behind it
> succeeds, which is the case that does not matter.

The discriminator was **whether `_sync_private_store` had anything to move** -
not the arguments. Every spelling of the subject crashed on an existing path:
a bare group name, `@group`, a real user, an unknown name, an empty string, an
array, a write list with no read list, `draft:true` alone.

## The state it left behind

This is what makes it serious rather than merely broken. The ACL is saved
**before** the move, so after a crashed call:

- the stored rule is complete, and `acl-get` returns it;
- pages answer 302 to an anonymous request - the rule is in force;
- **static files answer 200, byte-identical to the source**;
- `list_files` reports `"store": "public"` - the engine correctly saying the
  move did not happen;
- **the call is absent from the audit trail**, because the process died before
  the audit write. The trail and the stored ACL disagree about whether anyone
  protected that content.

A protected folder gating its pages and serving its images and archives is
[[SM283]] exactly - reached through the mechanism built to make it structurally
impossible.

`Lazysite::Private`'s invariant held throughout: the content was in exactly one
tree, and the failure direction was "not moved" rather than "in both". Nothing
was lost or duplicated.

## The cause

One line, from the [[SM286]] flip:

```perl
make_path($parent) unless -d $parent;
return ( 0, 'cannot create the private store' ) unless -d $parent;
```

That reads as though failure arrives as a false return.
**`File::Path::make_path` croaks.** So the guard on the second line was
unreachable, and the die went straight out through `action_acl_set`, past the
warning and past the audit write.

Both callers already handled a false return correctly. They only ever needed the
failure to *be* a return. `_mkpath` now captures the error and returns, and
`make_path` is no longer imported into that module at all - an unqualified call
is how this happened, and leaving the import there invites the next one.

## The contract this restores

The design anticipated this exact failure, and the reporter quoted it back:

> **A failed move does not refuse the rule.** The ACL is stored and the engine
> honours it, so the site is no worse off than before the store existed - but
> the response says so, because both outcomes look identical to the operator
> otherwise.

The warning text existed, and it is good text: it says the permission was saved,
the content could not be moved, the rule is in force, and that a front end
serving the files without asking the engine would not be covered. It simply
could not be reached.

The delivery path was proven working in the same session - the site-wide rule
returned its SM287 explanation in `warnings` over MCP. What was missing was
surviving the failure long enough to use it.

## Why the move failed there

Still open, and separable. The store is
`dirname($docroot)/basename($docroot)-lazysite-private`, so on the Hestia layout
it wants to create a directory in the domain folder beside `public_html`, which
may not be writable by the CGI identity.

`lazysite check` now answers that question on the affected host: it reports
whether the store exists and is writable, or whether it could be created, naming
the directory, its owner and its mode. It speaks only when the site actually
protects something - a site that has never gated a path will never try to create
the store, and failing every ordinary layout for an unused facility is the noise
this project keeps deciding not to ship.

## The upgrade consequence the report is right to press

`/zz-sm283/` has carried a read list since 0.10.7. After upgrading to 0.10.8,
untouched, **19 of 25 extensions were still served byte-identically to an
anonymous request**.

That matches the release note - the move happens on the act of protecting, and
nothing changes until asked. The behaviour is correct. The consequence needs
saying in the upgrade instructions rather than inferring:

> **Every section protected before 0.10.8 stays in the document root, and
> therefore stays exposed on any front end that serves statics by extension,
> until its rule is re-applied.**

"No operator action is required" is true of stability, and not of this. The
action is a re-apply sweep - and until this fix ships, that sweep is exactly the
operation that crashes.

## Related

[[SM286]] (the flip that introduced it), [[SM283]] (the exposure shape it fell
into), [[SM285]] (`check --check-acl`, which should FAIL on the affected site),
[[SM295]] (the trap-to-check work; this is a fourth candidate - a croaking call
in a request path), and the 0.10.8 validation brief in the inbox.
