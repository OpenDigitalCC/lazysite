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

# Correcting the control's scope

Retracted in part by the reporter, and it tightens the reasoning rather than
weakening it.

The control was a **`.txt`** in the content namespace. The pages they publish
successfully all afternoon are **`.md`**. So the control shows that one `.txt`
update took effect under `/sites/`; it does NOT show that the content namespace
is generally immune, and the heading above should be read with that limit.

More importantly it corrects what the `.md`-only guard explains. That guard
means `invalidate_cache` clears nothing for EITHER `.txt` - the mirror probe or
the content control. So the guard is not what separates the two namespaces.

::: widebox
The discriminator is not the extension and not the namespace as such. It is
**whether a stale cached copy exists for that path at all.** Something caches
what is served from `/lazysite-assets/`; nothing appears to cache
`/sites/<...>.txt`. The `.md` guard then matters as a second fact: even where a
cache DOES exist, a non-`.md` write will never clear it.
:::

That keeps the candidate intact and makes the shell questions above sharper. If
the probe file on disk holds the new bytes, the next thing to find is what is
holding the old ones for that path - and it will not be found by comparing
namespaces.

# Operational note for whoever fixes it

Delete-then-create is holding on the staging site and is now baked into the
publish batches there - six assets currently go through that path. A fix that
changes mirror-write behaviour will not break anything running, and the
workaround can be unwound afterwards rather than needing to be preserved.

# A measured contrast: the stale asset ignores query strings

From the field, on the same host and session, and it is the sharpest narrowing
so far:

```datatable
columns: Request | Result
widths: 8cm | X
bold: 1
tone: medium
---
`/sitemap.xml` | stale (a pre-move copy)
`/sitemap.xml?cb=1` | **fresh from origin** - a query defeats it
`/lazysite-assets/<L>/<T>/main.css?v=r3` | **stale, byte-identical to the unbusted URL**
```

Both carry `public, max-age=14400` with no `Age`, so the headers alone do not
tell the two apart. Worth stating, because reading the header set and
concluding "same layer" is the natural mistake.

::: widebox
**A query string cannot defeat a stale file on disk.** That is the inference
worth carrying into the shell step: if busting the URL changes nothing, the
bytes being served are most likely coming from a FILE at the served path rather
than from an HTTP cache in front of it - because an HTTP cache is the thing a
query key is able to miss, and this one does not miss.

Stated as an inference, not a result. It is consistent with everything measured
and it has not been confirmed on disk.
:::

If that reading holds, it revises the leading candidate rather than replacing
it: something is leaving an old FILE at the served path while the PUT's bytes
land elsewhere - and `do_put` has already told us they land somewhere, because
204 follows a successful rename.

# The shell step, revised

The earlier two questions stand, with one addition that follows directly from
the above. Look in BOTH trees:

1. Does `<docroot>/lazysite-assets/<L>/<T>/<probe>` hold the NEW bytes?
2. Does a copy of that path exist in the PRIVATE store
   (`Lazysite::Private::private_root`)?

Question 2 is worth asking because `resolve_for_write` returns the private path
when the file ALREADY resolves there, before it ever consults the public
ancestor - so an existing file with a private copy is written privately while a
new file at the same path is written publicly. That is the create/update
asymmetry exactly, it needs no cache at all, and it would leave a stale public
file serving under any query string.

**Not established.** It requires a private copy of that asset to exist, which
nobody has checked. It is now the first thing the shell step should look for,
ahead of hunting a cache.

# A near-miss worth recording

The same reporter was about to file "registry generation is per-content-root
for llms.txt but not for sitemap.xml", having seen the new subdomain serve its
own `llms.txt` while `sitemap.xml` carried the DEFAULT site's URLs, with
identical cache headers at the same instant. They ran a cache-buster before
filing: `?cb=1` returned the correct sitemap. Generation was fine and the
discriminator was an artefact of the cache in front of it.

Nothing was filed, and the reason it is recorded here is that the artefact
looked exactly like a clean finding - two registries, one host, one instant,
different content. On this host a plain-URL comparison of anything cached is
not evidence until it has been busted.

# WITHDRAWN: the query-string contrast, and the private-store step built on it

Retracted by the reporter, and the section above stands only as a record of
what was measured - **do not act on it**. The private-store question was aimed
at the operator on the strength of an inference that no longer holds, and this
section supersedes it.

A fresh probe in the mirror, in sequence:

```datatable
columns: Step | Observed
widths: 7cm | X
bold: 1
tone: medium
---
create 9 bytes | serves 9 bytes
update to 23 bytes | 204; plain URL unchanged, **same mtime, same etag**
DELETE, then create again | 201; plain URL **and** a busted key still the ORIGINAL 9 bytes
a short while later, second busted key | **new bytes**
then the FIRST busted key, then the plain URL | **new bytes**
```

::: widebox
**It converges.** Given time, the correct content appears at the plain URL with
no further action. That is a propagation delay - not a write landing somewhere
else, and not a frozen per-key cache.
:::

Why the earlier contrast was confounded: the `main.css?v=r3` read was taken
IMMEDIATELY after the PUT, and was never re-read later without a
delete-then-create in between. The sitemap comparison had several operations
between the write and the busted fetch, which gave it time to settle. So the
two halves differed in WHEN they were read as well as HOW, and only the HOW was
reported. "A query string does not defeat it" was never tested against elapsed
time.

Everything built on that difference goes with it: the file-not-a-cache
inference, and the private-store step it promoted. `resolve_for_write` returns
to being an unexamined candidate, no better placed than any other.

# What still stands, and the experiment that settles it

**Stands, reproducible:** an update PUT returns 204 and the served content does
not change IMMEDIATELY. That is what cost the reporter an afternoon and it is
the reason the filing exists.

**Not established:** that it never changes. The whole filing was written around
"stale" meaning permanent, and one timed re-read may dissolve it.

The experiment needs no shell and should run before anyone opens any code:
write, then re-read the plain URL at intervals WITHOUT deleting anything, and
record when it flips. If it flips on its own, this is a propagation window and
the questions become how long, whether that is documented, and whether anything
should invalidate sooner - which may be nothing at all.

A candidate consistent with every timing observation, offered as a candidate
only: a PATH-KEYED, time-limited cache at the front end - `open_file_cache` is
the archetype - would be query-insensitive, would converge on expiry, and would
survive a delete-then-create for the same window. The shipped nginx templates
set no such directive, so if that is the mechanism it comes from the host's own
configuration rather than from anything lazysite ships. Unverified.

# RESOLVED as measured: a ~30s cache entry that the READER populates

Timed runs from the field settle the question the filing was written around.
Plain URL, every 10s from +0s, no delete and no buster:

```datatable
columns: Run | Update at | Result
widths: 3cm | 5cm | X
bold: 1
tone: medium
---
1 | 16:52:52Z | stale at +0/+10/+20/+30, **flipped at +40s**
2 | 16:54:22Z | stale at +0/+10/+20/+30, **flipped at +40s**
no-poll | same write, no reads for 15s | **FRESH at +15s**
```

Identical windows from starts 90 seconds apart, so it is elapsed-since-write
rather than a clock boundary.

::: widebox
**The +0s read is what pins it.** The entry is populated by the FIRST READ
AFTER THE WRITE, holds the pre-write content, and lives about 30 seconds. Poll
immediately and you extend your own staleness to ~40s; stay quiet and the
content is correct within 15s. The observer was creating what it observed.

It also explains delete-then-create: DELETE invalidates the entry, so the
following create is read fresh. The workaround was never fixing a write.
:::

Everything the model predicts holds - query-insensitive because the key is the
path, converges on expiry, survives delete-then-create inside the window.

# What it costs this filing

The premise. "An update PUT returns 204 and the served content does not change"
was always a +0s reading. It changes on its own in well under a minute.

**There may be no lazysite defect here at all.** The operator's two disk
questions stay held - do not run them. If the mechanism is worth confirming it
is now a one-line check of the host's nginx configuration for a path-keyed file
cache (`open_file_cache` being the archetype), not a two-tree hunt for missing
bytes. The shipped templates set no such directive, so that would be host
configuration rather than anything lazysite ships. Inference; the timings above
are not.

# Two things deliberately not folded in

**The no-poll run is repeated: 4 for 4.** Three further runs were made after
this was flagged as a single observation, all FRESH at +15s, none stale -
against two timed runs that both went stale-until-+40s when read from +0s. The
load-bearing measurement now stands on four agreeing runs and the caveat is
withdrawn.

**This does not explain the sitemap staleness.** That persisted across roughly
90 minutes and three `regenerate-registries` calls - two orders of magnitude
longer, and unaffected by operations that should have rewritten it. Whatever
that is, it is not this, and folding them together on the strength of both
being "stale" would repeat today's mistake.
