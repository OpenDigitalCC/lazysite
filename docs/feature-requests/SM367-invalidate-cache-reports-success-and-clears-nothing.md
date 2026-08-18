---
title: "SM367 - invalidate_cache(\"/\") reports success and clears nothing"
subtitle: "`ok` meant a syntax check passed - not that a cache was cleared, and not that the page exists. On a migrated site it was worse than that: invalidating a legacy static page DELETED the page and reported that it had cleared a cache."
brand: plain
status: shipped
status-note: "SHIPPED 2026-08-18, found by the site agent during the 0.10.13 validation pass. Two fixes, and the second is the more important one: a directory path now resolves to its index, AND the response says how many renders it cleared. `ok:1` answered \"did the call succeed\" and was being read as \"the cache is now gone\" - different facts, and on the homepage they were different facts. Also worth recording that my first attempt at the fix appended /index unconditionally and broke `/index`, `/index.md` and `/index.html` - the three spellings that DID work and were the discovered workaround. Caught by the test in the same run; it is the ordinary way a fix for a silent no-op becomes a loud one."
---

# The finding got worse twice

It was filed as "`/` is accepted and does nothing". Digging produced the real
shape, and then reading the code for the fix produced a third thing nobody had
been looking for.

```datatable
columns: Call | Answer | What actually happened
widths: 6cm | 2.4cm | X
bold: 1
tone: medium
---
`/` | ok:true | nothing
`/index` | ok:true | cleared
`/nope.md` | ok:true | **the page does not exist**
`/definitely-not-a-page-zz` | ok:true | **the page does not exist**
`/nope/deeper.md` | ok:false | the page does not exist
`/legacy` (`.html`, no `.md`) | ok:true, cleared:1 | **THE PAGE WAS DELETED**
---
```

## Validation existed, and tested the wrong thing

It checked that the **parent directory** was present. So a page that does not
exist answered `ok:true` when its parent did and `ok:false` when its parent did
not - two identical situations, two different answers, differing on something
the caller never asked about.

That reframes this from a path-vocabulary bug into a **success flag reporting
the health of the request rather than the state of the world**, and it is why
"make `ok` mean something happened" is fixed here ahead of resolving `/`. A
caller could not distinguish *cleared*, *nothing was cached*, and *no such
path*.

## And it deleted pages

The last row is the one found while fixing the others. A bare `.html` with no
`.md` sibling is legacy static content served by the migration fallback - it is
the page itself, not a render of one. [[SM133]] taught the `*` sweep exactly
that. **This branch never learned it**, so on any migrated site
`invalidate_cache` on such a path unlinked the page and returned `ok:1` with
`cleared:1`.

A destructive act, described as a cache clear, with a success flag. Verified
against the code before fixing.

## And the first guard misfired

Field-checked the same day. `402.html` and `404.html` have **no `.md` sibling
and are engine renders** - their sources live in `lazysite/templates/system/`
(SM201), not beside them. So "no `.md` sibling" read them as pages to protect,
and the guard refused to clear exactly the artefact [[SM355]] was about: a
cached 404 in the served tree carrying a canonical a stranger chose.

Nothing was destroyed by that, which is why it is a misfire rather than a
regression - but it made the page most likely to need clearing the one page that
could not be cleared, and an operator has no other route to it.

Two cheap discriminators now run in order, so the refusal can say which case it
believes it has hit: a system-page source in the engine tree, then the engine's
own `<meta name="generator" content="lazysite">` marker in the file itself.
Anything with no source and no marker is migrated content, and is still refused.

## Reproduced live on the shipped build

The site agent called it deliberately on 0.10.13 to find out whether the refusal
had landed on edge. It has not, so the call went through:

```
list_files /                            404.html present, 4377b
invalidate_cache {"path":"/404.html"}   {"ok": true, "path": "/404.html"}
list_files / and PROPFIND /             404.html ABSENT
```

::: widebox
**The defect repairs its own symptom.** On an instance that regenerates you get
no error, a success flag and a working site. On a migrated instance the
identical call with the identical response destroys content. The two are
indistinguishable from the caller's side - and the benign one is what anyone
will happen to test against.
:::

That is why this is worth more than its size, and why "I ran it and nothing
broke" is the least useful evidence available here.

## The trace is erased by looking for it

Corrected the same day by the reporter, and it sharpens the defect rather than
softening it. From `list_files` mtimes:

```datatable
columns: Time | State
widths: 3.2cm | X
bold: 1
tone: medium
---
04:49:57 | `404.html` present, 4377 bytes
~05:04:2x | `invalidate_cache` returns ok:true, file unlinked
~05:04:3x | confirmed absent from PROPFIND and list_files
05:04:51 | **REGENERATED**, 4441 bytes
---
```

**The fetch used to check for damage is what repaired it.** Requesting the route
makes the engine render and write the file again, so the window in which the
deletion is observable is the gap between the call and somebody looking - and
looking closes it.

::: widebox
A destructive operation whose only trace is erased by the act of looking for it
cannot be validated by field testing at all. It has to be prevented in the code.
:::

That also retires the reassurance offered earlier - that two calls the previous
day had done no harm because the file was present. The file was present because
it regenerates, and the regeneration is fast enough that **no check made after
the fact could have distinguished "nothing happened" from "it happened and
healed"**. The evidence could not have come out any other way, which is the
definition of evidence that proves nothing.

## What edge could not have told us

The site agent had run `invalidate_cache` on `/404.html` twice on 0.10.12 -
precisely the dangerous shape, on a qualifying path - and the page is intact.
That is **not** evidence the defect was harmless.

Every bare `.html` on that instance regenerates: all eight root `.html` files
carry mtimes from after the deploy. A deletion there is repaired before anyone
looks. The blast radius is instances where the `.html` **is** the source and
nothing regenerates it - the migrated case - and edge is not one.

Recorded because "I ran it and nothing broke" is the most reassuring possible
evidence and, here, means nothing at all.

# The original mechanism, which is one line

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

- A legacy static page - `.html` with no source - is REFUSED and left on disk.
- A path with no page at all is refused, with the same answer whether or not its
  parent directory exists.
- `invalidate_cache("/")` clears the homepage's rendered HTML.
- A directory path clears that directory's index render.
- `/index`, `/index.md` and `/index.html` continue to work unchanged.
- A path with no cached render returns `ok:1` with `cleared: 0`.

# Related

[[SM110]] (the per-alias-host render copies this also clears), [[SM133]] (why a
bare `.html` with no `.md` sibling is never treated as a cache), and
`inbox/archive/2026-08-18-validation-0.10.13.md`.
