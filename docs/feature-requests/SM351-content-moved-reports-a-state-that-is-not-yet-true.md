---
title: "SM351 - `content_moved:1` reports a state that is not yet true"
subtitle: "Protecting a folder returns success and `list_files` confirms every entry is in the private store - while 23 of 31 previously-fetched files still answer 200 to an anonymous request, byte-identical, for up to a minute. The behaviour is known and bounded; the response contract is what is wrong."
brand: plain
status: candidate
---

# SM351 - the success report is a claim about the world

## Scope, stated first

This is **not** a re-opening of [[SM331]]. That filing is closed correctly
and its analysis is right: the residue is nginx's `open_file_cache_valid`
default of 60 seconds ageing out a descriptor it already held, the
severity is a bounded sub-minute transient, and the engine leaves nothing
in the served tree.

This is about what the tool *says* while that is true.

## What was measured

edge 0.10.12. A folder holding 31 files, identical 61-byte payloads across
31 extensions, all fetched anonymously once while public.

```
set_permissions {"path":"/zz-surv/","read":["nobody-zz"]}
  -> {"content_moved":1,"ok":1,"acl":{"owner":"claude-code","read":["nobody-zz"]},"path":"zz-surv"}

list_files {"path":"/zz-surv/"}
  -> 31 entries, store: private   (31 of 31)
```

Immediately afterwards, anonymous:

```datatable
columns: Probe | Result
widths: 7.4cm | X
bold: 1
tone: medium
---
31 previously-fetched files | **23 served 200**, byte-identical to source - including `.gz`, `.zip`, `.tar`
Files created after protection, never fetched | gated from the first probe
The same 31, re-probed after ~75 seconds | all gated
```

Both halves of the engine's report were true. Both were also compatible
with the public still downloading the content.

## Why the response contract is the defect

**`content_moved: 1` is not a description of an internal step.** A caller
reads it as *this content is no longer being served*. That is the only
reason to report it. For a file that had been fetched, it is false at the
moment it is returned, and stays false for up to a minute.

**The person most likely to be misled is the one in a hurry.** An operator
protecting something urgently - a document published early, a page with a
name that should not have been public - checks immediately. They will
fetch the URL, see 200, and either conclude the tool failed, or protect it
again, or panic. If instead they check and see 200 and then trust
`content_moved:1` over their own eyes, that is worse.

**Nothing anywhere says the transient exists.** Not the tool description,
not the response, not `docs/architecture/access-control-model.md`, not the
briefings. [[SM331]] documents it in the register, which is not where a
caller looks.

**It defeats the obvious verification.** The natural way to confirm
protection worked is to fetch the URL anonymously. That check returns the
wrong answer for a minute, which trains a caller to skip it.

## The fix, in preference order

**Invalidate the front end when content moves.** The strongest fix -
the residue is a cached descriptor for a file that no longer exists at
that path, and the engine knows exactly which paths it moved.

**Failing that, say so in the response.** Something a caller can act on:

```
{"content_moved":1,"ok":1,
 "serving_residue_seconds":60,
 "notice":"Files already fetched may continue to serve from the front end
           cache for up to 60 seconds. Content created or never requested
           gates immediately."}
```

**And document it where a caller looks** - the `set_permissions`
description and the access-control model, not only the register.

The number should come from the deployed front end rather than being
hard-coded, since `open_file_cache_valid` is an operator's setting and a
site that raised it would be told 60 while residue lasted longer.

## What NOT to do

Do not make `set_permissions` block until the residue clears. It would
turn a fast operation into a minute-long one to fix a reporting problem,
and a caller who wants the guarantee can poll.

Do not weaken `content_moved` to something vague. It is a useful and
specific signal; the fix is to make it true or to qualify it, not to blur
it.

## Verification

- After protecting a folder whose files were fetched while public, either
  an anonymous fetch gates immediately, or the response states the residue
  and its duration.
- A protected file never previously fetched gates on the first probe -
  unchanged, and the control that separates this from a disclosure.
- The stated residue is derived from the deployed front-end configuration.
- The `set_permissions` description mentions the transient.
- `docs/architecture/access-control-model.md` records what a caller may
  conclude from `content_moved:1` and what it may not.

## Related

[[SM331]] (the caching analysis, closed correctly - this filing depends on
it rather than disputing it), [[SM286]] (protection as a move, which is
what makes the engine side clean), and
`inbox/four-surface-validation-0.10.12-2026-08-17.md`.
