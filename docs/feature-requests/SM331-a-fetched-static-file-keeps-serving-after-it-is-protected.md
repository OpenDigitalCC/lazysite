---
title: "SM331 - A static file fetched before protection keeps serving after it"
subtitle: "The move succeeds and every file reaches the private store - and the two that had been fetched while public still answer 200 for up to a minute afterwards. Measured on the host: the front end is answering from a descriptor it already held."
brand: plain
status: shipped
status-note: "CLOSED 2026-08-16, MEASURED RATHER THAN INFERRED. The engine was cleared first: fetching a static leaves no copy in the docroot, and after protecting, every file is in the private store with nothing left in the served tree (t/integration/56). The partner agent then ran the decisive test on the host with nginx untouched - two files fetched while public, one never requested as the control. The fetched pair served at t+0 and t+30 and gated from t+60 onward; the control gated from the first probe. So the residue is a descriptor cache ageing out, the boundary is nginx's `open_file_cache_valid` default of 60 seconds, and the severity is a bounded sub-minute transient rather than a silent failure. Two things shipped from it: the probe now fetches its folder WHILE PUBLIC before gating, so the bound is asserted on every run instead of believed, and the access-control model documents the window - naming `open_file_cache_valid` because it is the number that decides it, while asking nothing of the front end and requiring no change to its default. FILED 2026-08-16 from a partner-agent pass on edge/0.10.11, immediately after the store permissions were repaired and protection began working from the control API."
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

### The proxy template is NOT the answer here

Recorded because the analysis above leads there and the project's standing
constraint forbids it: **lazysite requires nothing of the front end.** The engine
makes the decisions, nothing is added to nginx, and Apache configuration shrinks
rather than grows. That is the whole point of SM286 moving protected content out
of the document root - a front end that answers statics without asking cannot
reach bytes that are not there.

So "put the domain on lazysite-proxy.tpl" is not a remedy to reach for, even
though it would work. Edge sits behind nginx and Apache in a stock Hestia
configuration, and it must stay serveable that way.

**Which means the engine's answer is already the right one and is already
implemented**: the file is moved out of the docroot, so there is nothing at the
path. What remains is a front end answering from state it captured while the file
WAS there - bounded, not persistent, and not something the engine can prevent by
moving a file more thoroughly. `open_file_cache` is off by default in nginx and
self-heals when on.

That reframes what is left to establish: not "how do we make nginx behave" but
"how long does the residue last, and is it bounded". If it expires, the engine is
correct and complete and this is a documented transient. If it does not, the
assumption that moving the bytes is sufficient has a hole in it, and that is a
much larger finding.

### The decisive test - RUN 2026-08-16, and the residue is bounded

Run from the partner side against edge/0.10.11, nginx untouched throughout.
Three identical-byte files: `png` and `zip` fetched while the folder was public,
`pdf` never requested as the control.

```datatable
columns: Elapsed since protecting | d.png | d.zip | d.pdf (control)
widths: 5.4cm | 2.4cm | 2.4cm | X
bold: 1
tone: medium
---
0s | 200 | 200 | 302
30s | 200 | 200 | 302
**60s** | **302** | **302** | 302
180s | 302 | 302 | 302
300s | 302 | 302 | 302
600s | 302 | 302 | 302
```

**The residue expires between 30 and 60 seconds and does not return.** The
control gated from the first probe, so the difference is entirely the earlier
fetch.

That is outcome 2 of the three, and it is the one the project wants:

- the engine is **complete and correct** - the bytes are moved, nothing is left
  at the path, and `t/integration/56` needs no extension;
- the exposure is a **bounded transient of under a minute**, not a persistent
  leak;
- nothing is required of the front end, which is the standing constraint.

The window also identifies the mechanism. nginx's `open_file_cache_valid`
defaults to **60 seconds**, and the observed boundary sits exactly there. This
is a descriptor cache ageing out, as the analysis above inferred.

### What that changes about this filing

The severity drops from "protection silently fails" to "protection takes effect
within a minute on a front end holding a descriptor cache". That is a
documentation item rather than a code defect, and the number belongs in the
SM283 remediation guidance: after protecting content, a file that had been
fetched in the preceding minute may still be served for up to that long.

Two things are still worth doing:

The probe should construct the failing case
: `check --check-acl` creating, gating and fetching in one go cannot produce it.
  Warming the folder before gating is one extra request per extension, and it
  turns "we believe this is bounded" into something asserted on every run. This
  is already recorded as fixed in the status note.

The bound should be stated rather than assumed
: 60 seconds is nginx's default and an operator can raise it. The guidance
  should say the exposure lasts as long as the front end's descriptor or file
  cache validity, and name `open_file_cache_valid` as the setting that decides
  it - so a site that has tuned it upward knows what it has tuned.

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

## Measured on the host, 2026-08-16

Run by the partner agent on edge/0.10.11 with **nginx untouched throughout**.
Three identical-byte files; `png` and `zip` fetched anonymously while the folder
was public, `pdf` never requested as the control. The folder was then protected
and all three probed anonymously.

```datatable
columns: Elapsed | png (fetched) | zip (fetched) | pdf (control)
widths: 3cm | 3.2cm | 3.2cm | X
bold: 1
tone: medium
---
t+0s | 200 | 200 | 302
t+30s | 200 | 200 | 302
t+60s | **302** | **302** | 302
t+180s | 302 | 302 | 302
t+300s | 302 | 302 | 302
t+600s | 302 | 302 | 302
---
```

The control gates from the first probe, so the entire difference is attributable
to the earlier fetch. The residue expires between 30 and 60 seconds and does not
return.

**That identifies the mechanism.** A URL-keyed proxy cache was already ruled out
by the query-string test. A boundary landing exactly on nginx's
`open_file_cache_valid` default of 60 seconds is a descriptor cache: the front
end holds an open file handle from the earlier request and answers from it
without returning to the filesystem to discover the file has gone.

## What this changes

The engine is complete and correct. The bytes move, nothing is left at the path,
and `t/integration/56` needs no extension.

The severity drops from *protection silently fails* to **protection takes effect
within the front end's cache validity**. That is a documentation item, now
written into `docs/architecture/access-control-model.md`, which states the window
and names `open_file_cache_valid` as the setting that decides it - so an operator
who has raised it above the default knows what they have lengthened. Nothing is
asked of the front end and the default needs no change.

The probe's warming pass is kept. It is what turns "we believe this is bounded"
into a property asserted on every run.

## Verification

- A file fetched anonymously, then protected, returns 302 to a subsequent
  anonymous request **once the front end's cache validity has elapsed** - 60
  seconds on a default nginx. Confirmed on the host, with a never-fetched
  control gating from the first probe.
- No copy of a served file is left anywhere in the document root, so the move
  has nothing to carry that it does not carry. Confirmed against the engine by
  `t/integration/56`.
- The window is documented where remediation is described, and the setting that
  decides its length is named.
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
