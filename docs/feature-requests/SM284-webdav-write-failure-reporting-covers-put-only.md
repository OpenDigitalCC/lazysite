---
title: "SM284 - The WebDAV write-failure message covers PUT only; DELETE, MOVE, COPY and MKCOL still fail opaquely"
subtitle: "SM235 made a PUT into an unwritable directory explain itself. The other four verbs meet the identical condition and answer with a bare 500."
brand: plain
status: candidate
status-note: "FILED 2026-08-11 from the site agent's brief of 2026-08-10, re-confirmed by source on 0.10.6: lazysite-dav.pl still has five _write_failure call sites, all PUT-side. NOT STARTED. Sized S - the helper exists and the work is calling it from four more places. Lower urgency since SM270 repairs the condition that produced it at source, but not unreachable: any directory an operator tightens by hand reproduces it."
---

# SM284 - the other four verbs

## What SM235 got right, and should not be re-done

A PUT into an unwritable docroot answers exactly as intended:

```
507 PUT /zz-writetest.md
    Cannot create the file: the target directory is not writable by the
    server. This is a server configuration fault, not a permission
    decision about your request - the operator must fix the directory
    permissions.
```

Right status. Names the condition. Distinguishes a **server fault** from a
**permission decision** - which is the distinction that matters to an agent
deciding whether to retry, ask, or give up. Omits the filesystem path, per the
standing rule. The MCP surface goes further and names the remedy
(`lazysite check --fix`).

## What it does not cover

The identical condition, the identical directory, the other write verbs:

```
DELETE /zz-sm249.md          500  "Delete failed"
(MOVE / COPY failure path)   500  "Operation failed"
(MKCOL failure path)         409  "Cannot create collection"
```

`lazysite-dav.pl` has five `_write_failure` call sites and every one is PUT-side.
`do_delete` returns a bare 500; `do_mkcol` returns 409 with wording almost
identical to what it returns for a genuinely missing parent four lines earlier -
so two different faults are indistinguishable to the caller.

## Why it still matters after SM270

SM270 repairs the condition at source: the Hestia deploy now runs its permission
sweep last, so a rebuild no longer leaves the docroot unwritable. That makes this
much less likely to be met and does not make it unreachable - **any directory an
operator tightens by hand reproduces it**, and the agent that meets it gets a
bare 500 with nothing to act on.

It is also the general point rather than the specific one: a write path that
explains itself on one verb and not the other four is a half-built contract, and
the half that is missing is the half nobody tested.

## What to build

Route the four remaining failure paths through the same `_write_failure` helper,
so all five verbs give the same shape of answer: the status that distinguishes a
server fault from a refusal, the condition named, the remedy where there is one,
and no filesystem path.

`do_mkcol` additionally needs its two 409s to differ - a missing parent and an
unwritable parent are different problems with different fixes.

## Acceptance

- Each of DELETE, MOVE, COPY and MKCOL, against an unwritable target, returns a
  message that names the condition and distinguishes a server fault from a
  permission decision.
- MKCOL's missing-parent and unwritable-parent answers are distinguishable.
- No response contains a filesystem path.
- A test drives all five verbs against one unwritable directory and asserts the
  shape of each - the fixture is the same for all of them, which is most of why
  doing four together is cheaper than doing one.

## Related

[[SM235]] (the PUT half, shipped in 0.10.2), [[SM270]] (repairs the condition
that produced it), and the standing rule that filesystem paths are never exposed.
