---
title: "SM438: updating an existing mirrored theme asset over WebDAV is a silent no-op"
subtitle: "The PUT returns 204 and last-modified advances. The bytes do not change and the old content keeps serving. Creating a new asset works; delete-then-create works. Cause NOT established - this filing is the observation and the test that would settle it."
brand: plain
standard-margins: true
status: candidate
status-note: "FILED 2026-08-20 from the field, on 0.10.19, and DELIBERATELY WITHOUT A CAUSE. What was observed: a PUT over WebDAV to an EXISTING asset under /lazysite-assets/<layout>/<theme>/ returns 204, the last-modified advances, and the bytes are unchanged - the old content keeps serving. Creating a NEW asset at that path works. Deleting then creating works, and is the reporter's publish workaround. The etag encoded the OLD length while last-modified was fresh, which is the sharpest clue in the report: the file on disk appears to carry a fresh mtime and stale content, so something wrote the old bytes rather than the write never landing. That points at the ORIGIN rather than at anything in front of it, and the reporter reached the same conclusion independently. WHAT I CHECKED AND WHAT IT RULED OUT: no code path in lazysite-dav.pl calls _mirror_theme_assets, and the four callers that exist are layout activation, theme activation, domain_set and site-package apply - none of which a PUT triggers. So 'the write lands and is immediately re-mirrored from source' has no mechanism I can find, and I am recording that as a ruled-out candidate rather than leaving it as the obvious guess. A second candidate remains open: the DAV write path routes through Private::resolve_for_write, so an existing file and a new file at the same path can resolve to DIFFERENT destinations - which would explain create-works / update-does-not exactly, without needing anything to overwrite afterwards. I have NOT established that it resolves differently here, and it should not be quoted as the cause. WHY IT IS FILED WITHOUT A DIAGNOSIS: today produced two cases in this repo of a plausible cause being reported as settled and being wrong, and the standing correction is to say when a cause has not been isolated rather than name the nearest one. The observations are solid and reproducible; the mechanism is not known. THE TEST THAT SETTLES IT: after a 204 PUT that leaves the served bytes stale, find every file on disk holding the NEW bytes. If they are somewhere other than the served path, the write is being redirected and resolve_for_write is the place to look. If the new bytes are nowhere, the body is being consumed and discarded. If they are AT the served path but an older copy is served, the fault is in front of the origin after all and the etag reading needs revisiting. Those three outcomes are mutually exclusive and each names a different file to open. NO URGENCY from the reporter: the staging site is working and delete-then-create is a usable workaround."
---

# What was observed

```datatable
columns: Operation | Result
widths: 7cm | X
bold: 1
tone: medium
---
PUT over an EXISTING mirrored asset | 204, last-modified advances, **bytes unchanged**
PUT creating a NEW asset | works
DELETE then PUT | works - the reporter's workaround
`etag` after the failed update | encodes the **old** length
`last-modified` after the failed update | **fresh**
```

::: widebox
A fresh mtime with stale content is the whole clue. It is not the shape of a
write that never happened - it is the shape of a write of the wrong bytes, or
of a write that landed somewhere other than the file being served.
:::

# Candidates

**Ruled out - re-mirror after write.** The obvious guess is that the PUT lands
and something immediately re-mirrors the asset from the theme source. Nothing
in `lazysite-dav.pl` calls `_mirror_theme_assets`, and its four callers are
layout activation, theme activation, `domain_set` and site-package apply. A PUT
triggers none of them. Recorded as ruled out rather than left as the natural
assumption.

**Open - the write is redirected.** The DAV write path resolves through
`Private::resolve_for_write`, which decides a destination partly on where the
file already exists. An existing file and a new file at the same path can
therefore resolve differently, which would produce create-works /
update-does-not exactly, with nothing overwriting anything afterwards. **This
is not established.** It is where I would look first, and it should not be
repeated as the cause.

# The test that settles it

After a 204 PUT that leaves the served bytes stale, locate every file on disk
holding the NEW bytes.

```datatable
columns: Where the new bytes are | What it means
widths: 7cm | X
bold: 1
tone: medium
---
Somewhere other than the served path | the write is redirected - open `resolve_for_write`
Nowhere | the body is consumed and discarded - open the PUT handler
At the served path | the fault is in front of the origin, and the etag reading needs revisiting
```

Three outcomes, mutually exclusive, each naming a different file. Worth running
before anybody proposes a fix.

# Why no diagnosis is offered

Two findings in this repo today were reported with a plausible cause attached
and the cause was wrong in both. The standing correction is to say plainly when
a cause has not been isolated rather than to name the nearest one that fits.
The observations here are solid and reproducible. The mechanism is not known,
and the filing says so rather than guessing well.
