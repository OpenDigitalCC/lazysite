---
title: "SM283 - A protected section gates its pages and serves its images, PDFs and text to anyone"
subtitle: "SM223's enforcement is correct. Most static requests never reach it, because lazysite's own nginx guidance tells the front end to serve them directly - and which ones gate is decided by file extension."
brand: plain
status: candidate
status-note: "FILED 2026-08-11 from the site agent's brief of 2026-08-10, re-confirmed against 0.10.6 on 2026-08-11 with the correct Apache template installed. NOT FIXED. This is a LIVE, FAIL-OPEN DISCLOSURE on deployed sites: anonymous requests retrieve byte-identical copies of gated .png, .pdf, .txt and .bin files. Measured, not inferred - same 11829 bytes uploaded under five extensions into one ACL'd folder, four served, one gated. Sized M and the first hour is a decision, not code: whether the front end excludes ACL-covered paths or all statics route through the engine."
---

# SM283 - the front end serves what the ACL refuses

## The measurement

One folder, one ACL (`upcoming`, owner/read/write `claude-code`), and the **same
11829 bytes** uploaded under five extensions so nothing varies but the name:

```
upcoming/pricing            302  -> /login?next=%2Fupcoming%2Fpricing
upcoming/probe.dat          302  -> /login?next=%2Fupcoming%2Fprobe.dat
upcoming/secret-asset.png   200  11829 bytes, byte-identical
upcoming/probe.bin          200  11829 bytes, byte-identical
upcoming/probe.txt          200  11829 bytes, byte-identical
upcoming/probe.pdf          200  11829 bytes, byte-identical
```

Fetched anonymously, with no credential of any kind. `cmp` against the source
returns identical for each 200.

Re-measured on 0.10.6, before a rebuild, after a rebuild, and after the new
Apache template was installed - identical status codes and identical response
headers all three times.

## Why `.dat` is the important line

`.dat` gates. That proves [[SM223]] works: **where a request reaches lazysite,
the ACL is enforced exactly as designed.** The failure is entirely about which
requests get there, and that is decided by extension - which is to say, by
whichever list the front end happens to treat as static.

**Deciding this by extension cannot be made safe.** Any list is a list of the
types that happen to be protected, and everything left off it is silently public.

## The cause is ours

`tools/lazysite-nginx-vhost.pl` publishes the multi-site static guidance, and its
own description is the defect:

> Static files for each alias domain then serve directly from its content root;
> clean page URLs and /lazysite, /cgi-bin, /manager still reach the processor.

That is the bypass, and lazysite tells operators to configure it. So this is a
product defect, not a deployment quirk - a site following our documentation
arrives here.

The disclosed responses corroborate it: a served file carries
`expires: Thu, 31 Dec 2037`, an `etag` and a `last-modified`, and **none** of
`x-content-type-options`, `x-frame-options` or `referrer-policy` - which lazysite
puts on everything it serves, its own 404 included. The auth wrapper is not in
the path.

## Why this is worse than it looks

**The bypassed set is exactly what a protected section is for.** Images, PDFs,
text and binaries. An operator who protects `/upcoming/` and puts a draft price
list, a pre-release PDF or an unpublished photograph in it has protected the page
describing them and published the things themselves.

**It is silent.** The operator sets the ACL, loads the page, is bounced to
`/login`, and has every reason to conclude the section is protected. Nothing in
the manager, the audit trail or the API contradicts that.

**It shipped alongside a loud failure and hid behind it.** H17 was fail-CLOSED -
a static 404ing - and got noticed immediately. This is fail-OPEN, and three probe
runs across two rebuilds produced byte-identical responses. An operator following
the release note has done everything asked of them and has no way to tell from
outside whether anything changed.

## What to decide first

**Either** the front end carries an exclusion for ACL-covered prefixes, **or**
statics under a protected prefix route to the auth wrapper before any static
handler claims them. The second is safer and slower; the first is faster and
needs the exclusion regenerated whenever an ACL changes, which is a
synchronisation problem with a fail-open failure mode.

My inclination is the second for correctness, with the performance question
answered by measurement rather than assumption - a protected section is a small
fraction of a site, so the cost applies to little of the traffic.

## Acceptance

- The fixture above: one ACL, the same bytes under five extensions, **all five
  gate**. It fails today on four of five, and belongs in `t/` at whatever level
  the fix makes reachable.
- An **observable** that the fix landed. Today there is none - which is its own
  finding. A header, a log line, or a documented probe that returns differently
  before and after, so an operator can confirm rather than trust.
- The nginx guidance in `lazysite-nginx-vhost.pl` no longer tells operators to
  configure the bypass.

## Related

[[SM223]] (the engine enforcement, correct), [[SM267]] (the panel that tells an
operator a section is protected), [[SM248]] (the last time front-end routing made
correct engine code unreachable), [[SM268]] H17 (the fail-closed sibling).
