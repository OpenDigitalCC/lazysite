---
title: "SM367 - invalidate_cache(\"/\") reports success and clears nothing"
subtitle: "The root path became `$DOCROOT/.html`, a file that has never existed, so the unlink found nothing and the call returned `ok:1` anyway. It cost two wrong diagnoses before anyone suspected the tool."
brand: plain
status: shipped
status-note: "SHIPPED 2026-08-18, found by the site agent during the 0.10.13 validation pass. Two fixes, and the second is the more important one: a directory path now resolves to its index, AND the response says how many renders it cleared. `ok:1` answered \"did the call succeed\" and was being read as \"the cache is now gone\" - different facts, and on the homepage they were different facts. Also worth recording that my first attempt at the fix appended /index unconditionally and broke `/index`, `/index.md` and `/index.html` - the three spellings that DID work and were the discovered workaround. Caught by the test in the same run; it is the ordinary way a fix for a silent no-op becomes a loud one."
---

# The mechanism, which is one line

```perl
my $full = "$DOCROOT$rel_path";
$full .= '.html' unless $full =~ /\.html$/;
```

`"/"` becomes `"$DOCROOT/.html"`. Nothing has ever been at that path, so the
`unlink` below found nothing, and `ok:1` was returned regardless.

`/index`, `/index.md` and `/index.html` all worked, which is why this survived:
the tool was demonstrably functional to anyone who tried it a second way.

# What it cost, which is why it is worth more than its size

It produced **two wrong diagnoses rather than two errors**, and both were
plausible:

after a layout upgrade
: invalidating `/` changed nothing, and the conclusion drawn was that a stale
  `index.html` was shadowing the page. It was not.

during the 0.10.13 validation
: the homepage served a 0.10.12 render on a 0.10.13 instance, read as a failed
  upgrade. An engine upgrade does not invalidate rendered pages, and the
  homepage is both the page most likely to be checked and the one most likely to
  be stale.

It also broke a version probe that read the homepage alone and reported 0.10.12
on a 0.10.13 instance. A query string does not help: it busts client caches, not
the render cache, which is keyed by path.

::: widebox
A silent no-op on the most-checked page of a site does not cost you a failed
call. It costs you the next hour, spent on a theory the tool invited.
:::

# Why the response changed as well as the resolution

Fixing the path alone would have left the same shape available on any other path
whose render happens not to exist. `cleared` is now a count, so a caller can
tell a page that had no cached render from one whose render was dropped - and
`cleared: 0` is a true and useful answer rather than a silent one.

That is the same correction SM337 made to activation and SM344 made to a
rollout: the control states what it established, not merely that it ran.

# Verification

- `invalidate_cache("/")` clears the homepage's rendered HTML.
- A directory path clears that directory's index render.
- `/index`, `/index.md` and `/index.html` continue to work unchanged.
- A path with no cached render returns `ok:1` with `cleared: 0`.

# Related

[[SM110]] (the per-alias-host render copies this also clears), [[SM133]] (why a
bare `.html` with no `.md` sibling is never treated as a cache), and
`inbox/archive/2026-08-18-validation-0.10.13.md`.
