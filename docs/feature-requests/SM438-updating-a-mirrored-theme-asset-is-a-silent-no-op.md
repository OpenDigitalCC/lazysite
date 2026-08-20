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

# Narrowed: it is the namespace, not WebDAV

A controlled reproduction from the field, on a throwaway file rather than the
live CSS, with a CONTROL - which is what turned this from a symptom into a
bounded fault:

```datatable
columns: Path | Create | Update
widths: 8cm | 3cm | X
bold: 1
tone: medium
---
`/lazysite-assets/<L>/<T>/sm438-probe.txt` | 201, correct | **204, still the old 17 bytes**
`/sites/dhcf/sm438-control.txt` | 201, correct | 204, **takes effect**
`lazysite/layouts/<L>/themes/<T>/assets/` (source) | works | works
```

Same client, same helper, same session. So this is not "WebDAV updates" and not
"updates that answer 204". It is specific to the `/lazysite-assets/` mirror
namespace. The probe was a plain file the reporter created themselves, which
also rules out anything peculiar to mirrored files as such - it is the
namespace, not the file.

# What the code settles

**"Nowhere / discarded" is ruled out.** `do_put` reaches `send_status(204)`
only after `rename $tmp, $r->{abs}` succeeds; the failure branches call
`_write_failure` and return an error instead. A 204 therefore PROVES the bytes
landed at `$r->{abs}`. That is the outcome the field put its weight on, and it
cannot be the answer - the write is going somewhere, just not to the file being
served.

**A named candidate that fits create-works / update-does-not.** The DAV
`invalidate_cache` acts **only on `.md`**:

```perl
sub invalidate_cache {
    my ($abs) = @_;
    return unless $abs =~ /\.md$/;
```

So a PUT of a `.css` or a `.txt` clears nothing. If any cached copy of that
asset exists, a create has none to be stale (falls through, serves the new
file) and an update leaves the old one standing - with an etag computed from
the stale copy, which is the old length observed. Same family as SM433: a write
that updates one location while the server keeps reading another.

**The only create/update asymmetry in the resolution path** is in
`resolve_under_docroot`, which rewrites the target through `realpath` when, and
only when, the file already exists:

```perl
if ( -e $full ) { my $tr = realpath($full); ...; $full = $tr; }
```

That is exactly the shape of the fault. It bites only if the final component
resolves elsewhere, which a plain file the reporter created should not - so it
is named as the second place to look rather than the answer.

# What is still not settled, and by whom

The reporter has WebDAV and HTTP on that host and no shell, and said so rather
than reporting a partial sweep as a sweep. Locating the new bytes needs
filesystem access, so the remaining step belongs to whoever has it. Two
questions, in order:

1. Does `<docroot>/lazysite-assets/<L>/<T>/sm438-probe.txt` hold the NEW bytes?
   If yes, the write is fine and the fault is in what serves it - go to the
   cache candidate above.
2. If no, where did they land? That answers it outright.

Also retracted from the original report, by the reporter, and worth keeping
visible: the FRESH last-modified was observed on `main.css` earlier and was not
re-captured under controlled conditions. Do not lean on it. Without it the
"write of the wrong bytes" reading loses its main support, and the cache
candidate gains.
