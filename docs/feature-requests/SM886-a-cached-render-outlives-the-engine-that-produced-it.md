---
id: SM886
title: "SM886: a cached render outlives the engine that produced it"
subtitle: "An upgrade changes no source, and a render is judged against its source - so a page nobody edits keeps its pre-upgrade render for ever. SM413 fixed this in 0.10.18 for the slot the homepage is not in: the sweep walks lazysite/cache/, and the primary host's render is the sibling .html beside the .md. The engine is now the fourth dependency of a render, beside the conf, the nav and the section indexes."
brand: plain
standard-margins: true
status: shipped
status-note: "CONFIRMED FROM OUTSIDE 2026-09-15, which is the only evidence that counts for this one: after the estate-wide 0.14.2 deploy the sites agent read all twenty registered sites on both measures - engine from a fresh, uncacheable 404 and served from the home page - and every row reads 0.14.2. None is in the split state that was the defect. The decisive detail is the cadence: their fleet monitor diffs on a seven-minute tick, the tick before showed 0.14.1 engines with SIX sites serving older HTML, and the tick at 10:49 showed all twenty current - THE STALE COUNT WENT SIX TO ZERO IN ONE TICK WITH NO CACHE INVALIDATION FROM ANYONE. A sweep would have needed someone to run it; nothing was run, so the renders stopped being served because they stopped being valid. FIXED 2026-09-15, RULED by the release manager the same day ('do the page cache, version the cache key'). REPRODUCED FIRST - t/integration/99 renders under one installed version, moves the install state on and nothing else, and before the fix the next request serves the old build's render. The engine's install state now participates in the render's freshness check, in the same running max that already carries lazysite.conf, the nav file and the section indexes. ONE LINE COVERS BOTH SLOTS, which is the point: the check is shared by the primary host's sibling .html and the alias hosts' entries under cache/hosts, so it reaches the slot install.pl's sweep never did. Keyed on the install state's MTIME, not its version string, so a ROLLBACK invalidates too - 'different from the render' is the property, not 'newer'. A site with no install state is unaffected. FIELD EVIDENCE: the sites agent, 2026-09-14, measured ten sites answering a fresh uncacheable 404 as 0.14.1 while serving home pages rendered by 0.14.0 or 0.13.15, five of them two releases behind on the page a visitor lands on."
---

# What a visitor gets

A page rendered by an engine that is no longer installed. Not a stale copy of
the right page — the *right* page as an older build produced it, including that
build's head contract, its security headers and its asset cache-busting tokens.

The site reports the new version honestly on anything uncached, so every check
that asks the engine says the upgrade worked. The check that asks a *visitor*
says otherwise.

# Measured, twice, eleven months apart

[[SM413]], August 2026: a homepage serving a 0.10.13 render through **four**
deployments, corrected only when an operator invalidated it by hand.

The sites agent, 2026-09-14, on twenty registered sites:

| | |
|---|---|
| answer a fresh 404 as 0.14.1 (uncacheable, rendered live) | 13 |
| of those, still serving a pre-0.14.1 **home page** | 10 |
| of those, two releases behind (0.13.15) | 5 |

The two that were current were current only because their home pages had been
re-PUT that day, which invalidates that one page.

# Why the existing fix did not cover it

SM413's fix is real and it works — on the slot it walks. `install.pl`'s
`invalidate_rendered_html` (`install.pl:1123`) sweeps
`lazysite_dir_for($docroot)/cache`.

**There are two cache slots, and the homepage is in the other one**
(`lazysite-processor.pl:2430` and `:2465`):

| host | where the render lives |
|---|---|
| primary | `<content-root>/<base>.html` — a **sibling beside the `.md`** |
| alias | `<docroot>/lazysite/cache/hosts/<host>/<base>.html` |

So the sweep covers alias hosts and has never touched the primary host's
pages. On a single-domain site that is every page, and the homepage is the one
page an operator never edits and always checks first — which is why the failure
presents as "the upgrade did not take".

[[SM434]] recorded exactly this in August and it was read as an explanation
rather than as an open defect: *"an upgrade OVERWRITES every shipped page so
those re-render by themselves, and the operator's own index.md is PRESERVED
precisely because it is operator-edited - so the one page that keeps an old
render is the homepage"*. That is the defect, written down and left.

# The fix

A render already has three dependencies that are not its source, all folded
into one running max in `try_serve_cache` (`lazysite-processor.pl:2126-2150`):
`lazysite.conf`, the nav file, and every ancestor section index. Each was added
when a stale page proved the render depended on something the check did not
know about.

**The engine is the fourth**, and this adds it. A render bakes the engine into
itself — the generator meta, the `?v=` busting tokens, the head contract, every
header the build emits — so it is a dependency in exactly the sense the other
three are.

## Why the install state is the file to watch

It is what the installer rewrites on every install, upgrade and rollback, and
it is already the source of the version the render *reports*. So the fact the
page claims about itself and the fact its cache is judged on are the same fact,
read from the same file. Nothing new has to be maintained, and there is no
second place for the truth to drift to.

## Why mtime and not the version string

"Different from the render" is the property that matters, not "newer". Keyed on
mtime, a **rollback** invalidates too — which a version comparison would have to
special-case, and which is the direction SM413's own sweep was originally
written for.

## Why not a versioned filename

The literal reading of "version the cache key" is to put the version in the
path. That was considered and rejected on blast radius: the render's filename is
load-bearing in at least ten places that derive it by rewriting `.md` to
`.html` — `Util.pm:371/397`, `Files.pm:1189/1400`, `lazysite-dav.pl:1834`,
`Themes.pm:836/2058/2112/2174`, `install.pl:1123` — and for the primary host it
is also the file the front end serves directly. Versioning it changes what a
web server looks for.

The freshness check delivers the ruled property — a new engine never serves an
old render — in one place that both slots already consult, instead of a rename
that ten call sites would have to learn about.

# What this does not do

- **It does not delete anything.** Stale renders are not swept; they are simply
  never served, and each page re-renders once on its next request. At the
  measured cost of a render ([[SM693]]: the cache saves 23.7ms of a 93.5ms
  request) that is one page-render per page actually visited.
- **It does not change a running worker's behaviour.** `_engine_mtime` is
  memoised per process like `_lazysite_version`, so a persistent worker that has
  not been restarted goes on serving the renders of the engine it is *actually
  running*, which is correct. [[N142A]] restarts the workers an upgrade touches.
- **It leaves `install.pl`'s sweep in place.** That sweep is now redundant for
  correctness — the check no longer needs anything to have been deleted — and
  keeping it only means alias-host pages re-render eagerly rather than lazily.
  Whether to remove it is a separate question and a separate change; flagged
  rather than taken, because a compensation layer should be removed
  deliberately and not as a side effect.

# Related

[[SM413]] (the same defect, fixed for the other slot), [[SM434]] (which
recorded the homepage case and closed), [[SM693]] (what the cache is worth),
[[SM536]] and [[SM812]] (the nav and section-index dependencies, the same
pattern), [[SM830]] (a theme's assets cached against the engine version — the
mirror image of this, on the asset side).
