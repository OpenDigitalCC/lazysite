---
title: "SM381: the refusal paths bypass the header choke point, and the snapshot failed because the site was live"
subtitle: "402, 403 and three other refusals printed their own headers and carried none of the baseline set; two of them also rendered into the PRIMARY docroot on a multi-domain instance. And the safety snapshot treated tar's 'some files differ' warning as fatal, which is why a busy site could not be snapshotted at all."
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED 2026-08-19 on claude/sm380-csp-rollout-mode, before the cut. Found by the pre-beta review. FIVE refusal paths now route through output_page; 402 and 403 resolve the DOMAIN's content root as SM253 did for the 404; the error-page writer gained the checked write and umask the main cache writer has documented 300 lines above it since SM020. AND THE FIELD FAILURE IS EXPLAINED, not merely diagnosable: tar exits 1 for 'some files differ' and the snapshot treated that as fatal, so one visitor triggering a render during the tar refused the whole apply. Reproduced 3 times out of 3 with the old behaviour and 0 out of 3 with the fix."
---

# Part 1: five refusals with no security headers

`serve_402`, `serve_403`, the ACL static refusal, the manager-access
refusal and `forbidden()` all printed their own status line and content
type. None called `_security_headers`, so none carried nosniff, frame
options, HSTS or the CSP.

::: widebox
**The comment on `_security_headers` claimed "every response path here
calls this". It was not true**, and had not been since it was written -
the paths that skip it are the refusals, which is to say the responses a
scanner is most likely to reach.
:::

All five now route through `output_page`, which is the choke point that
exists for exactly this.

# Part 2: two of them wrote into the wrong docroot

`serve_402` and `serve_403` called `_system_page_md` with no content
root and hard-coded `"$DOCROOT/40x.html"` for the cache slot. On a
multi-domain instance, **domain B's refusal page was rendered into
domain A's docroot and then served to both** - one site's branding and
navigation shown to a visitor refused on another.

This is the defect [[SM253]] fixed for the 404, in the same file, not
carried across to its two neighbours.

# Part 3: the error-page writer had no checked write

`_rewrite_if_changed` - the writer for the cached 404/402/403 files -
checked neither `print` nor `close` before renaming into place, and
omitted `_cache_umask()`. That is the [[SM020]] torn-page defect the main
cache writer guards against and documents 300 lines earlier in the same
file: a disk-full mid-write renamed a truncated error page into place,
and it was then served from cache.

# Part 4: why the safety snapshot failed on a live site

A partner agent's `site_apply` refused with "safety snapshot failed"
while `site_backup` on the same host succeeded minutes later, in both
directions. [[SM378]] made the refusal say why; this is what it was going
to say.

**tar exits 1 for a warning** - a file changed or vanished while being
read - **and 2 for a fatal error.** The snapshot treated both as fatal.
The render cache writes `<page>.html.tmp.<pid>` into the docroot and
renames it away, so a single visitor arriving mid-backup lets tar
enumerate a file that is gone before it can be opened.

```datatable
columns: Behaviour | Result over 3 runs against a live docroot
widths: 6.0cm | X
bold: 1
tone: medium
---
Any non-zero fatal (as shipped) | **3 of 3 refused**, "tar exited 1"
Warning tolerated, archive verified | 3 of 3 succeeded
---
```

It predicts every symptom reported: intermittent, traffic-correlated,
invisible to a manual backup taken at a quiet moment, and reproducible
only on a site with traffic.

The fix excludes the cache's transient tempfiles - restoring one would
put a half-written page into a site - and accepts exit 1 **only when the
archive is present, non-empty and readable as a gzip stream**. A warning
plus a valid archive is a backup; a warning plus a broken one is still a
failure.

# Part 5: two adjacent defects in the same function

- `make_path` was unchecked, so a permissions failure surfaced two
  frames later as "could not claim a filename" - naming the wrong thing
  entirely.
- The STDERR capture SM378 added redirected **this process's** STDERR
  around the `system()` call. In a persistent worker that sends every
  unrelated warning to a temp file for the duration of a multi-second
  tar, and leaves STDERR redirected for the life of the worker if the
  call dies between the two opens. It is a fork/exec now, so the
  redirect happens in the child and the parent is never touched.

# Verification

- 402 and 403 responses carry the full baseline header set.
- Each resolves its own domain's content root.
- A snapshot of a docroot being actively written succeeds; a fatal tar
  still fails and still says why.
- Reverting the tolerance fails the live-site test with "tar exited 1".

# Related

[[SM253]] (the 404 fix these two never inherited), [[SM020]] (the
checked write), [[SM378]] (which made this diagnosable), [[SM183]] (an
apply must be reversible).
