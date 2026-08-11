---
title: "SM284 - The WebDAV write-failure message covers PUT only; DELETE, MOVE, COPY and MKCOL still fail opaquely"
subtitle: "SM235 made a PUT into an unwritable directory explain itself. The other four verbs meet the identical condition and answer with a bare 500."
brand: plain
status: shipped
status-note: "SHIPPED on main (unreleased). All five write verbs now answer with the same shape: DELETE, MKCOL, MOVE and COPY route through _write_failure, which gained a per-path ROLE so MOVE can name WHICH of its two directories failed - 'the target directory' would have been a guess presented as a fact. An unlabelled path still defaults to 'target', which keeps PUT's wording byte-identical to what SM235 shipped. MKCOL's two 409s are now different answers: a missing parent stays 409 and says the parent does not exist (the CALLER acts), while an unwritable parent is the 507 server fault it always was. TWO DEFECTS FOUND while building the source-side MOVE case, neither in the filing: (1) the copy-then-remove fallback never checked the removal, so a MOVE out of an unwritable directory copied the entry, failed to remove the original and answered 201 - a MOVE silently downgraded to a COPY with both copies live and the client told otherwise; (2) once that was fixed, a failed MOVE left the copy behind, so the rollback removes it - reporting failure while leaving an entry the caller never asked to create is the same defect one step further on. TESTS: t/integration/41 is BEHAVIOURAL, driving the real CGI against one genuinely chmod-0555 directory for all five verbs and skipping as root; 24 assertions confirmed failing with lazysite-dav.pl stashed to HEAD, and the PUT case plus a full writable-directory pass are controls that pass either way. That matters because SM235's own test is a SOURCE-TEXT test - unavoidable on a root CI image - and a source match proves a call site exists, never that the response is right, which is how four verbs stayed uncovered. t/unit/dav/12 extended to pin the parity. docs: the publishing briefing now tells an agent all five verbs answer this way, that MOVE names source or destination, and that MKCOL's 409 is the caller's to fix."
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

## What the fixture found that the filing did not

Both of these were reachable only by building the source-side MOVE case, and
neither is about error messages.

**A MOVE could silently become a COPY.** `rename` fails across a device
boundary, so there is a copy-then-remove fallback. The removal was performed for
effect and its result never looked at, so `$ok` was already true from the copy.
A MOVE out of an unwritable directory therefore copied the entry, failed to
remove the original, and answered **201**: both copies live, and the client told
it had moved. This is the SM278 shape - a write path reporting success for work
it did not do - in a different file.

**And then a failed MOVE left the copy behind.** Once the removal decided the
outcome, the entry it had already written at the destination stayed there while
the response said the operation failed. Reporting failure while leaving
something the caller never asked to create is the same defect one step further
on, so the copy is rolled back.

The general point: **the message was the symptom.** Four verbs answered
uselessly because nobody had driven them through the failing condition, and
nobody had driven them through it because the one test that existed was a source
match. A source match proves a call site exists. It cannot tell you the response
is right, or that the operation did what the status claims.

## Related

[[SM235]] (the PUT half, shipped in 0.10.2), [[SM270]] (repairs the condition
that produced it), [[SM278]] (the same shape - success reported for work not
done), and the standing rule that filesystem paths are never exposed.
