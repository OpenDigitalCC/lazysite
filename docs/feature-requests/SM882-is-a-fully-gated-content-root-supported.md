---
id: SM882
title: "SM882: is a fully gated content root a supported configuration?"
subtitle: "SM852's S9 - the per-content-root theme mirror recreates a fully gated content root - cannot be fixed until the question under it is answered. The filing already said so: 'Whether a fully gated content root is a supported configuration is open.' This splits the question out so it can be decided on its own rather than blocking a patch."
brand: plain
standard-margins: true
status: candidate
status-note: "RULED 2026-09-14 by the release manager: a fully gated content root IS supported, AND it must contain nothing public - so the theme assets move OUT of it. See 'The ruling' below for what that settles and what it opens. Previously DEFERRED 2026-09-14 - 'needs some thought, file and defer to further discussion and decision'. Split out of SM852 (S9), which was graded from reading and NOT reproduced. The behaviour and the fix both depend on a product ruling that has never been made: a content root every page of which is protected is a site that serves nothing anonymously, and it is not clear whether that is a configuration lazysite means to support or an accident an operator can arrive at. Deciding it settles S9, narrows SM881 (the git-sync pull), and tells lazysite-check whether such a root is a state worth reporting."
---

# The row this came from

SM852, S9: *"the per-content-root theme mirror recreates a fully gated content
root. Whether a fully gated content root is a supported configuration is open."*

The mirror writes a domain's theme assets into its content root. If every page
of that root is protected, the root exists only in the private store — and the
mirror recreates it publicly to put the CSS somewhere servable.

# Why it is a question and not a defect

A content root with *some* protected folders is ordinary and well supported. A
content root where **everything** is protected is different in kind: the domain
serves nothing to an anonymous visitor, and the only traffic it can answer is
authenticated.

Two readings, and the code does not choose between them:

- **Supported.** A private site — a client portal, an internal handbook — is a
  reasonable thing to build, and the theme assets have to be served for the
  authenticated pages to look right. The mirror is then correct to create a
  public directory for CSS, and S9 is not a defect at all.
- **Not supported.** Then the mirror is quietly producing a public directory
  under a root the operator believes is entirely private, and the fix is to
  refuse the configuration, or to serve those assets from somewhere that is not
  inside the gated root.

The same evidence reads as correct behaviour or as an exposure depending on
which answer is intended. That is the definition of a question that has to be
decided before it can be built.

# MEASURED 2026-09-27, and S9's premise does not hold

This filing said twice that nobody had stood a fully gated content root up and
watched the mirror run, and that confirming the reading was the first task. It has
now been done, and **the reading measures false**: there is nothing public inside
such a root to move out.

Probe `tmp/probe-sm882.pl` on the 0.15.0 tree - a docroot with content root
`shop`, one entry `{"shop":{"read":["@staff"]}}`, and a theme asset mirrored where
`Themes.pm` puts one today:

    the gated root's own page                governed=YES
    a theme asset inside the gated root      governed=YES
    page  (shop/index.md)                    anonymous read=refused
    asset (shop/lazysite-assets/.../main.css) anonymous read=refused
    /assets/lazysite-chrome.css              engine_asset_carve_out=YES
    /shop/lazysite-assets/.../main.css       engine_asset_carve_out=no

Three facts behind it, each read from the serving code and then measured rather
than either alone:

1. **SM223 applies the ACL gate to a static.** `_acl_refused` is called on the
   static serve path (`lazysite-processor.pl:3447`).
2. **The mirror gets no carve-out from it.** `_is_engine_asset` is an EXACT list
   of three URIs - the two chrome assets and the data helper - and
   `/lazysite-assets/` is not among them. That list is deliberate and commented
   as deliberate, so the absence is a decision rather than an omission.
3. **The rule reaches the asset.** A rule on the content root's own key governs
   every path beneath it, by the ancestor-prefix step `_acl_entry_for` has carried
   since SM287. The asset path is beneath it.

So a gated content root's assets are governed by the same rule as its pages and
refused by the same ladder. **The mirror was never the exposure this filing
assumed, and the relocation the ruling asked for would buy no protection.** It was
built and then reverted on this measurement rather than shipped.

## What this leaves, and what it does not

**The ruling's first half stands untouched and needed no work:** a fully gated
content root IS a supported configuration, and it keeps its styling - which the
measurement also confirms, because the assets are served to a visitor who can see
the pages, over the same authenticated path.

**The invariant is now vacuous inside the engine's own contract.** Nothing under a
gated root is served without the gate, so `a gated content root contains nothing
public` is true by construction and a check asserting it would always pass. This
filing anticipated exactly that: *"if the mirror turns out not to do this, the
ruling costs nothing and the invariant is still worth checking for."* It is worth
saying plainly that on the engine's own serving path there is nothing left for
such a check to catch.

**The residual risk is a FRONT END that serves statics directly**, bypassing the
engine and its gate. That is not this filing - it is [[SM283]], which routed
statics through the engine and is pinned by `t/lint/31`, and whose proxy template
was still recorded as not installed on edge. A gated root on a host without that
template is exposed, and the exposure is the front end rather than the mirror.

## Back to the release manager

The ruling was made on a reading, as it said. The reading is now measured and
does not hold, so:

- S9 is **not a defect**. Nothing needs to move.
- The mirror's contract needs **no exception**, so the destination question that
  was "the first design question of the work" does not arise.
- `Acl::root_gating` was built anyway, under [[SM881]], and is exported - so if a
  check for this invariant is ever wanted for the front-end case, the answer it
  needs already exists.

What remains is a decision rather than work: whether to keep this filing open
against the front-end case, which [[SM283]] already owns, or to close it here.

# The ruling

**2026-09-14, the release manager: both halves.** A fully gated content root is
a **supported** configuration — a private site is a real thing to build, and it
keeps its styling. **And** a gated content root contains **nothing public**: the
theme assets for such a site are served from somewhere that is not inside it.

So the first reading above is right about the *configuration* and wrong about
the *mirror*. S9 is a real defect with a clear fix, and the fix is not to refuse
anything an operator has built.

What makes this ruling worth more than either single answer is that it converts
an open question into an **invariant** — *a gated content root contains nothing
public* — and an invariant is a thing `lazysite check` can assert. Neither of the
other two answers left anything checkable behind: one made the current behaviour
correct, the other made the operator's configuration the fault.

## What it does not yet settle

**Where the assets go instead.** The ruling fixes that they leave the gated
root; it does not say what replaces it, and I am not going to invent the
destination. That is the first design question of the work, and it has to be
answered against how the front end actually resolves a theme asset URL, not in
the abstract.

Read after the ruling, against the code:

- The mirror is `Manager::Themes::_mirror_theme_assets`
  (`lib/Lazysite/Manager/Themes.pm:1021`). The per-content-root loop is
  `Themes.pm:1114`, writing `$DOCROOT/$cr/lazysite-assets/$layout/$theme` by
  `cp -r` into a staging directory and `_swap_in`.
- **It consults nothing.** Not `acls.json`, not `Lazysite::Private`, not
  `resolve_for_write`, not `write_root`. So there is no existing decision to
  change — there is a decision to *introduce*.
- `Private.pm:133` declares a write under `lazysite-assets/` unconditionally
  public, and says why at length (the mirror's `cp -r` is the canonical writer,
  so the one write path that disagreed with it lost). **That rule is anchored:**
  `m{\Alazysite-assets(?:/|\z)}` matches the docroot's own mirror and **not**
  `$cr/lazysite-assets`. Verified by reading, not inferred. The two mirrors are
  therefore already governed differently, which is worth knowing before anyone
  reasons about "the mirror" as one thing.

**The destination I would argue for, and the reason it is not obvious.** Put a
fully gated root's assets in the **private store**, beside the pages they style.
The instinct is that this cannot work because gated CSS is refused — but this
root serves nothing anonymously by definition, so every visitor who can see a
page can see its stylesheet, fetched over the same authenticated path. Nothing
public, styling kept, no new location invented.

That is a proposal and not a finding. It has to be checked against the static
serve path (`lazysite-processor.pl:1034`, `_acl_refused`, SM223) before it is
believed — a gated *static* is a different code path from a gated *page*, and
whether it authenticates the same way is exactly the kind of thing that reads
true and measures false.

## Reproduce first — this has still never been seen

The section below is unchanged and still governs: nobody has stood up a fully
gated content root and watched the mirror run. The ruling says what to do **if**
the reading is right. Confirming the reading is the first task, before any of it
is built — if the mirror turns out not to do this, the ruling costs nothing and
the invariant is still worth checking for.

# What the answer settles

- **S9 itself** — defect, or documented behaviour. → **Defect.**
- **[[SM881]]** — a pull into a fully gated root is the sharpest case of the
  same exposure, and how much it matters depends on whether such a root is
  meant to exist. → **It is meant to exist, so the exposure is fully in
  scope.** SM881 was ruled the same day, and the two rulings meet: SM881 puts an
  ACL-aware resolver in the engine, and *"is this root fully gated?"* is a
  question for exactly that resolver. Build it once, and it answers both.
- **`lazysite check`** — if it is unsupported, a fully gated content root is a
  state worth reporting to the operator, and nothing reports it now. → **The
  root is not what gets reported; a public file inside one is.** The check
  asserts the invariant, and a private site on its own is silent.
- **The theme mirror's contract** — whether "assets live in the content root" is
  unconditional, or has an exception. → **It has an exception**, and the
  exception needs a destination (see above).

# Not reproduced

SM852 graded this row from reading and so is this filing. The purge and the seed
rows from the same list both reproduced exactly as written, so the reading is
likely right — but nobody has yet stood a fully gated content root up and
watched the mirror run, and that should happen before anything is built either
way.

# Related

[[SM852]] (this was its S9), [[SM881]], [[SM286]], [[SM438]].
