---
title: "SM334 - the settings file was re-parsed on every token verification"
subtitle: "touch_credential calls read_settings to decide whether a timestamp is stale. Its comment calls that one cheap read; it was 1.37 ms of JSON parsing, on every authenticated request."
brand: plain
status: shipped
status-note: "SHIPPED for 0.10.12, out of SM327's attribution. read_settings is memoised per process, keyed on the file's (mtime, size) rather than a clock - this decides who may do what, so a stale entry is an access-control answer from the past. Two holes keying alone leaves are closed: a file written within the last second is never cached (mtime is one-second granular, and a capability flip like \"ui\":1 -> \"ui\":0 keeps the size identical), and write_settings clears the cache so a process cannot answer from what it just superseded. Measured 1.3727 ms -> 0.0045 ms per read on a settled 40-user file."
---

# What was found

`touch_credential` records credential use so Sessions & Keys can show "last
used". To decide whether the stamp is stale enough to rewrite, it needs the
stored timestamps - so it calls `read_settings()`, **on every token
verification**. Its own comment describes this as

> one cheap read, a write only when the stamp is stale

`read_settings` opened, slurped and `decode_json`'d the entire user-settings file
each time, with no memoisation. Under the FastCGI pool, one worker did that for
every authenticated request it served.

Measured on a settled 40-user file:

```datatable
columns: | per read
widths: 8.4cm | X
bold: 1
tone: medium
---
before | 1.3727 ms
after | 0.0045 ms
---
```

# How it was found

Not by profiling. SM327 recorded that the engine had drifted 9-26% slower than a
six-week-old baseline and that re-capturing the baseline would have hidden it.
Bisecting the release line put the one step above the noise floor between v0.7.24
and v0.7.26 - the window that added this read (SM163).

# What it is worth, stated honestly

**About half the step, not all of it.** The v0.7.24-v0.7.26 window is 40 commits
and the step is +2.9 ms; this accounts for roughly 1.4 ms of it.

And it does not move `verify_token_ms` measurably, because that operation is
dominated by credential hashing, which is deliberately expensive. A 1.4 ms saving
on a 41.7 ms number is inside the noise. The value is in requests that resolve
settings several times - capabilities, groups, domain access - where the saving
compounds, and in a long-lived worker where the parse repeats indefinitely.

Recorded this way because the temptation was to present a 300x number as a 300x
improvement. It is a 300x improvement to one call that was never the dominant
cost of the operation it sits in.

# Why the cache is keyed the way it is

This decides who may do what, so a stale entry is an access-control answer from
the past: a capability revoked through the CLI would keep working until the entry
expired. Keying on the file's **identity** rather than on a clock means a write
invalidates it and correctness does not depend on a window being short enough.

Keying alone leaves two holes, both closed:

mtime is one-second granular
: a write in the same second with the same size carries an identical key, and
  `"ui":1` to `"ui":0` is exactly that shape. A file younger than a second is
  read fresh every time until it settles.

a process must not answer from what it superseded
: `write_settings` clears the cache. The (mtime, size) key covers *another*
  process writing; this covers the case where a capability change and the next
  authorisation are milliseconds apart in the same worker.

The map is capped, because a worker outliving many writes would otherwise
accumulate one entry per version it ever saw.

# Related

SM327 (the drift this came out of, and where the attribution lives), SM163 (which
added the read, for a good reason that is unaffected by this), and the
processor's `_peek_md`, whose per-(path, mtime) memoisation is the same shape.
