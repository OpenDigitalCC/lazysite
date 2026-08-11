---
title: "SM278 - Two silent successes: a dropped draft flag, and a published MCP schema nobody enforced"
subtitle: "set_permissions with draft:true returned ok and stored an ACL without it. The cause was general - all 51 MCP tools declared additionalProperties:false and none of them checked."
brand: plain
status: shipped
status-note: "SHIPPED on main (unreleased). Both halves built and covered by t/unit/manager/65, every assertion confirmed FAILING with the fixed files stashed to HEAD (5 of 8 fail; the other 3 are controls that pass either way and are labelled as such). FOUND by the site agent re-testing 0.10.6 on edge.explore: 'set_permissions with draft:true returns ok:1 and stores an ACL containing only owner, read and write. A security setting that reports success and does nothing.' The report named one tool; the mechanism reached all of them."
---

# SM278 - two silent successes on the same path

## What the site agent saw

Re-testing 0.10.6 on `edge.explore.lazysite.io`:

> `set_permissions` with `"draft": true` returns `ok: 1` and stores an ACL
> containing only `owner`, `read` and `write`. Unchanged on both surfaces. A
> security setting that reports success and does nothing.

Exactly right, and there were two independent reasons for it.

## Cause 1: the writer never carried the field

`action_acl_set` built its record from `owner`, `read` and `write` and nothing
else. [[SM181]] shipped the ENGINE half of `draft` - a draft prefix 404s to the
public, stays out of the sitemap, the feeds and every `scan:` listing, and
remains previewable by a signed-in editor - and every one of those paths reads
the flag correctly. Nothing could ever set it except by hand-editing
`acls.json`, which is what [[SM267]] exists to fix.

`draft` is now a first-class argument on the manager API, MCP and the module.
The rule for an ABSENT value is the one with security weight: absent means
*leave it as it is*, so an update that only changes the read list cannot publish
a held-back section by omission. An explicit `false` publishes, deliberately.

## Cause 2: the published schema was never enforced

Every one of the 51 MCP tools declares its properties and
`"additionalProperties": false`. That declaration was sent to the client at
`tools/list` and **never checked at `tools/call`** - `$args` went straight to
the tool's `run` sub. So any argument a tool did not support was silently
dropped and the call reported success.

That is the general case of what the agent found. `draft` was simply the first
unsupported argument anyone happened to pass; a typo would have behaved
identically, and an agent has no way to discover that its argument did nothing.

`validate_args` now enforces the schema at dispatch, AFTER the channel and
capability gates - so a caller without the capability is told that, rather than
given a schema critique of a call it was never allowed to make. Unknown
arguments are refused by name, with the accepted list; missing required
arguments are refused by name.

One existing test changed as a result: `site_backup` with no `host` used to come
back as a tool result with `ok:0` and now comes back as a JSON-RPC error naming
the argument. The assertion was strengthened rather than relaxed - it now pins
that the caller is told WHICH argument is missing.

## Why they are one filing

They are the same failure, and fixing either alone would have left the other. A
`draft` that the writer carried but the schema silently swallowed on a
neighbouring tool would still have shipped a lie; a schema gate over a writer
that drops the field would refuse nothing and change nothing.

## The general lesson

**A declaration that is published and not enforced is worse than no declaration**,
because a caller reads it and reasonably believes it. The capability model gets
this right - it refuses loudly and says why. The argument surface was doing the
opposite next door to it.

## Related

[[SM181]] (the draft engine), [[SM267]] (the panel that needs this writer to
work), [[SM239]] (MCP / control-API parity), [[SM243]] (warn at the point of
writing).
