---
title: "SM388: a comment claiming a capability that did not exist, and a skip that fired when it was most needed"
subtitle: "The front door justified its design on conditional GET and byte ranges the engine had never implemented. And t/lint/42 skipped route parity precisely when the processor's structure changed - the condition that makes the check necessary."
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED 2026-08-19. Conditional GET is now IMPLEMENTED rather than the claim withdrawn, because SM387 made every engine-served static revalidate and without a validator each revalidation was a full re-download - the expensive way to be correct. Weak ETag from mtime and size, If-None-Match answered with a 304 carrying no body and the full security header set. BYTE RANGES REMAIN ABSENT and are now recorded in the comment that used to deny it. t/lint/42's skip_all became a failure."
---

# Claim one: a justification resting on nothing

`lazysite-front.pl` explained why the front door does not reimplement
the static path:

> it already serves content statics, so the front door does not
> reimplement byte ranges, conditional GETs or content types - three
> things that are easy to get subtly wrong and that **the engine already
> gets right**.

Two of the three did not exist anywhere. `Range`, `ETag`,
`If-None-Match`, `If-Modified-Since` and `Last-Modified` appear **zero
times** in the processor.

::: widebox
**A justification resting on a capability that is not there is worse
than none**, because it stops the next reader looking. Anyone wondering
whether statics revalidate would have read that comment and moved on.
:::

# Why it was fixed rather than corrected

[[SM387]] settled that engine-served statics must revalidate - they are
public now and can be protected at any moment, so a long cache would
outlive the protection. Right, and it has a cost.

**Without a validator that cost is a full re-download on every
navigation.** With one it is a 304 and no body. The correctness of
SM387's choice is unchanged; what changes is that an operator stops
paying for it in bytes.

Weak, from mtime and size, because that is what `stat` can honestly
assert - a strong validator claims byte-identity and two writes inside
one second would break the claim. Hashing every file on every request is
the cost this exists to remove.

**Byte ranges are still absent**, and the comment now says so. Media
seeking fails wherever the engine answers a static.

# Claim two: a skip that fired when the check was most needed

`t/lint/42` pins the front door's copy of the routing table against the
processor's. It began:

```perl
plan skip_all => 'processor structure changed; fix the extraction above'
    unless $route_block && $dir_block;
```

The extraction fails **when the processor's structure changes** - which
is exactly when the copy is most likely to have drifted from it. So the
condition that made the check necessary was the condition that turned it
off, on the serving path.

A skip reads as "nothing to check here" to anyone scanning a run.
Absence of evidence being read as a pass is what [[SM319]] exists for.
It is now a failure with a diagnostic that names what to do.

# Verification

- A static carries a weak ETag; a matching `If-None-Match` gets a 304
  with a zero-length body; a stale one gets the file.
- The 304 carries the security header set - a 304 is a response like any
  other, and [[SM381]] is about precisely this class of path answering
  without them.
- Renaming the pinned sub makes `t/lint/42` FAIL rather than skip.

# Related

[[SM387]] (the revalidation this makes affordable), [[SM319]] (a skip
must not read as a pass), [[SM381]] (every response path carries the
headers).
