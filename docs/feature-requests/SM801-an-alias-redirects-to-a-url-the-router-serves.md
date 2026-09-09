---
id: SM801
title: "SM801: an alias redirects to a URL the router serves"
subtitle: "From the field on 0.12.1, VERIFIED STILL PRESENT ON 0.13.9: canonical_url_for builds a directory-index page's URL as /dir, and the router serves that page at /dir/ and nowhere else. So an alias on an index page 301s to a URL that 404s - correctly issued, and landing the visitor on a dead end."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-09 on claude/sm801-an-alias-redirects-to-a-url-the-router-serves. canonical_url_for keeps the trailing slash for an index page, so the redirect targets the URL the router actually resolves. t/unit/lib/43 is the guard the reporter asked for, done statically: it follows every alias target the way sanitise_uri would and asserts a file answers it, plus a check that the router's own rule has not drifted from the copy this test transcribes. The assertion in t/unit/lib/13 that said '/foo' was ENCODING THE BUG and is corrected with the reason."
---

# The finding, and what was verified here

Reported on 0.12.1. The first thing checked was whether it still stands on
current main, and it does - this is not a fixed-since issue:

- `canonical_url_for('case-studies/index.md')` returned `/case-studies`.
  Reproduced by calling it.
- `sanitise_uri` appends `/index` **only** when the request carries a trailing
  slash (`processor:2910-2913`); without one it looks for `case-studies.md`,
  which an index page does not have. So `/case-studies/` serves and
  `/case-studies` does not.
- **The engine says so about itself.** `processor:688`: *"`private.md` renders
  at `/private` and `private/index.md` at `/private/`"*. The two halves of the
  engine disagreed in writing, and the half that computes an alias target was
  the wrong one.

The reporter's evidence is exact: the alias machinery is faultless. The
registry builds, the redirect is issued, the 301 is correct - and it lands on a
404. Every part reports success, which is why nothing in the authoring path
could report it. Only following the redirect shows it.

# Why it survived this long

**It does not always 404.** `/dir` is also the request that reaches the
legacy-static fallback (`processor:1585-1600`), so an index page that happens
to have a `dir.html` sibling appears to work. That is why the shipped starter's
`/docs/features` - moved to `features/index.md` under SM432 - still serves: a
`features.html` sits beside the directory and answers it.

That is worth recording precisely, because **SM432's status-note states the
false premise in so many words**: *"canonical_url_for maps foo/index.md to /foo
- so the published URL /docs/features is unchanged"*. The URL is not unchanged;
it is answered by a different file. The remedy SM432 chose was still the right
one for the reason it gave (it degrades safely against a reinstall), and the
default nav item it was worried about does resolve - but not for the reason
recorded, and not by the page it names.

# What was built

`canonical_url_for` keeps the trailing slash for an index page. The root index
is `/` as before; an ordinary page is unchanged.

    case-studies/index.md  ->  /case-studies/     (was /case-studies)
    a/b/index.md           ->  /a/b/              (was /a/b)
    distributors.md        ->  /distributors      (unchanged)
    index.md               ->  /                  (unchanged)

**The bare path is not what was fixed, and that is the operator's ruling.** A
directory index answering only at `/dir/` is deliberate - an unmatched bare
path is a dependable 404 hook - so the redirect moves to the URL that is
served, rather than the router learning a second spelling. The reporter reached
the same conclusion after the ruling and said so.

**An existing site keeps its old targets until it is reindexed.** The map holds
computed strings, so a site with an alias on an index page needs
`regenerate_registries` (or any save of that page) before the redirect moves.
Worth saying in the reply, because "it still 404s" after an upgrade is the
obvious next report.

# The guard

The reporter proposed it: *for every alias, follow the redirect and assert the
target resolves.* `t/unit/lib/43` does that statically - it resolves each
target the way `sanitise_uri` would and asserts a file answers it, so it costs
no server and no requests.

It transcribes the router's rule, which is a copy and could drift, so a third
subtest reads `sanitise_uri` and asserts the rule it transcribed is still
there. The two have disagreed once; the test says so if they do again.

# Provenance

`inbox/2026-09-09-aliases-on-an-index-page-redirect-to-a-404.md`. Accepted after
reproducing both halves against current main. Related: [[SM432]].
