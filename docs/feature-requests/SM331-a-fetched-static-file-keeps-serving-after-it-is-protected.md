---
title: "SM331 - A static file fetched before protection keeps serving after it"
subtitle: "The move succeeds, content_moved is 1, list_files reports every entry private, and the two files that had been requested earlier still answer 200 to an anonymous request. The leaked set is exactly the set somebody had already looked at."
brand: plain
status: partial
status-note: "INVESTIGATED 2026-08-16, AND THE ENGINE IS CLEARED. Reproduced locally against the real engine: fetching a static leaves NO copy of it in the docroot, and after protecting, all five files are in the private store with nothing remaining in the served tree (t/integration/56). So move_in is complete and the leak is downstream of it. What is fixed here is the PROBE - it created, gated and fetched in one go, so its files were never requested while public and it could not generate the failing case at all; it now warms the folder before gating. What is NOT fixed is the front end, which is where the remaining evidence points: see the analysis added below. FILED 2026-08-16 from a partner-agent pass on edge/0.10.11, immediately after the store permissions were repaired and protection began working from the control API. Reproduced deliberately with a controlled fixture: five identical files, two fetched before protecting and three not. The two fetched keep serving; the three not fetched gate. Unique query strings do not defeat it, which rules out a URL-keyed proxy cache and points at a public copy left in the served tree. This is SM283's shape reached by a new route, and the route is one an ordinary visitor walks."
---

# SM331 - the move is complete and the file is still served

## What was measured

On edge, 0.10.11, with the private store working correctly for the first time -
`content_moved: 1`, which is what makes this visible.

A folder with five files of identical bytes. Two were fetched anonymously
**before** the folder was protected. Three were not touched.

```datatable
columns: File | Fetched before protecting | Anonymous request after protecting
widths: 3cm | 5.4cm | X
bold: 1
tone: medium
---
`c.png` | Yes | **200 - served**
`c.zip` | Yes | **200 - served**
`c.pdf` | No | 302 - gated
`c.css` | No | 302 - gated
`c.txt` | No | 302 - gated
```

`list_files` on that folder afterwards reports **every one of the six entries,
including `c.png` and `c.zip`, as `"store":"private"`.**

So the engine moved everything, believes everything is moved, and reports the
move as complete. The front end serves two of them anyway.

## It is not a URL cache

The obvious first explanation is a proxy caching the response. It does not hold:

```
GET /zz-cache/c.png?a=526349   -> 200
GET /zz-cache/c.png?b=zzz      -> 200
GET /zz-cache/c.png            -> 200
```

Three distinct cache keys, three 200s, on fresh connections. A response cache
keyed by URL would miss on the first two. The bytes are coming from somewhere
the front end resolves by path, with the query ignored - which is what a static
file on disk looks like.

The response also carries `cache-control: max-age=315360000` and an `etag`
matching the file's size, which is the static-asset handling, not a page render.

## Why this one matters

**The leaked set is the interesting set.** These are not random files. They are
exactly the files somebody requested while the folder was public. On a site
being protected after the fact - which is the whole SM283 remediation story, and
what `acl reapply` exists for - the documents that were fetched while public are
the documents that were worth fetching.

**Every signal says it worked.** `content_moved: 1`, `store: private` on every
entry, no warning, and the pages gate. There is no field in any response that
distinguishes this folder from one that is fully protected. An operator
following the SM283 remediation to the letter, on a correctly-repaired store,
finishes with content still served and nothing telling them so.

**It defeats the outside-in probe as currently written.** [[SM285]]'s
`check --check-acl` creates its own probe folder, gates it, and fetches it.
Because the probe files are created and gated in one operation and never fetched
while public, they are precisely the case that works. The check would report the
site healthy while this folder leaks - the same shape as SM283, where a
one-extension probe reported a leaking site healthy.

## Investigated 2026-08-16: the engine is not the leak

Reproduced against the real engine with the same fixture - five identical-byte
files, two fetched before protecting.

```datatable
columns: Question from this filing | Answer
widths: 6.4cm | X
bold: 1
tone: medium
---
Does serving a static write a copy under the docroot? | **No.** The only artefacts a request creates are a 404 page, a Template Toolkit compile cache and an access-log line.
Does `move_in` know about that location? | **No such location.** Nothing is left to carry.
Does the front end resolve against another directory? | **This is where it must be.**
---
```

After protecting, all five files are in the private store and **none remains in
the docroot**. `t/integration/56` holds that, so if the engine ever does start
leaving a copy, it fails there.

### What the evidence then points at

Taking the field observations together, and remembering that `expires max` and an
etag matching the file's size are nginx's static handling rather than a page
render:

- **only files that had been fetched** are affected - so something that retains
  state on access
- **the query string is ignored** - so it is keyed by path, not by request URI
- the bytes arrive on fresh connections

That is the shape of nginx serving a static from a **cached file descriptor**.
This project already documents that hazard, in
`installers/hestia/lazysite-hestia-deploy.sh`, for a different symptom: with
`open_file_cache` enabled, nginx can serve a stale view of a just-rewritten file
until `open_file_cache_valid` expires. A file whose backing has been *moved away*
is the same situation, more sharply.

### And the site was not on the lazysite proxy template

Measured on edge the same day: `curl -sI` returns no `X-Lazysite-Front`, so the
domain is on a **stock** nginx proxy, which serves static extensions straight off
the docroot with no ACL awareness whatsoever.

`installers/hestia/lazysite-proxy.tpl` already solves this. Its SM223 branch
sends **every** static request back to the engine once the site has an ACL store,
precisely so that protecting a path is a pure content action. A domain on that
template cannot exhibit this, because nginx never answers for the file.

**So this is very likely SM283 on a site that never received the remedy**, with
the fetched-only pattern explained by nginx retaining what it had opened - rather
than a new defect in the move.

### The decisive test, for whoever has the host

Stated because this is inference from outside, not proof:

1. Reproduce the fixture and confirm the two fetched files still serve.
2. `systemctl reload nginx`, then re-request them. If they now gate, it was
   nginx's cached state and the remedy is the proxy template.
3. If they still serve, something holds a copy on disk and the engine is back in
   scope - in which case `t/integration/56` is the place to extend.

## Where to look

This is the shape of the third defect found during the [[SM286]] flip: *"A page
moved without its `.brief` and without its `.html` render cache - the cache
being a complete public copy of the page left in the docroot, i.e. SM283."*

That one was found for pages. This is the same class for static files: fetching
one appears to leave a public copy that `move_in` does not carry with it, and
whatever writes that copy does not know about the private store.

The specific questions, in the order I would ask them:

- Does serving a static file write a copy anywhere under the docroot, and if so
  where?
- Does `move_in` know about that location for a file, the way SM286 taught it
  about `.html` and `.brief` for a page?
- Does the front end resolve a static path against any directory other than the
  one the move empties?

I cannot answer these from outside; every one of them is a question about the
filesystem, and the measurement above is the whole of what a partner surface can
see.

## Verification

- A file fetched anonymously, then protected, returns 302 to a subsequent
  anonymous request.
- The same holds with a query string, with a fresh connection, and after any
  cache TTL a front end might apply.
- A folder in this state is reported as such rather than as fully protected -
  either the move fails loudly or the leftover is cleared.
- `check --check-acl` catches it. That needs the probe to **fetch its files
  while they are public and then gate them**, which is one extra request per
  extension and is the only version of the probe that would have found this.
- Un-protecting and re-protecting a folder in this state ends in a correct
  state rather than a persistent one.

## Related

[[SM283]] (the exposure this reproduces), [[SM286]] (the flip, and the render
cache left behind - the same class for pages), [[SM285]] (`check --check-acl`,
which does not currently construct the failing case), [[SM323]] (the permission
repair that made the private store work, and therefore made this visible), and
`inbox/0.10.11-validation-2026-08-16.md`.
