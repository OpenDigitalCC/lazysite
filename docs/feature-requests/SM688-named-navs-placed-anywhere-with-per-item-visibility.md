---
id: SM688
title: Named navs, placed anywhere, with per-item visibility
raised: 2026-08-29
raised-by: release manager
area: navigation
status: candidate
status-note: "OPEN. Two requests sharing one format change: (1) a nav ITEM visible only to named users/groups; (2) MORE THAN ONE nav, named, includable where the builder wants, styled by name. THE CACHE QUESTION IS SETTLED AND SMALLER THAN IT LOOKED: the processor already refuses to cache any page carrying an auth level or group restriction, naming both hazards in its own comment (a stale menu, and one user's gated menu leaking to another), so per-viewer nav is already safe on gated pages. The cost falls on PUBLIC pages, which are the ones the cache exists for. Fragment composition - a cached shell with one nav-shaped hole - is the answer rather than per-viewer cache keys or a PWA, and it is possible because once acls.json exists the front end routes requests through the CGI rather than serving rendered HTML directly. Part 2 is half-built: per-DOMAIN nav files exist (`nav_file`), so the engine already resolves more than one nav - it just cannot NAME or PLACE them."
---

# Two requests, one format

From the release manager, 2026-08-29:

> you should have filing to add read permissions to nav renders, so the nav
> item is only visible to user/group specified. alongside this nav work, nav
> could be more flexible. sometimes different nav required for example for the
> intranet section. so instead of manually building it, adhoc navs can be
> created, and then they can be included wherever. probably the nav name would
> link to css descriptor to allow styling variations [...] plus with option to
> mark who can see the nav option. the nav editor then has a list of navs
> present through current dropdown, and ability to add nav, then edit it. on
> the nav line, add expander below to set source, dest, user/groups, styled as
> the files expander

They are one filing because they need the same thing: `nav.conf` is a
line-based format with nowhere to put per-item metadata.

```
Home | /
Discover
  Authoring | /docs/authoring
```

`Label | /url`, indentation for nesting, and no third field. Both halves of
this request are per-item metadata - who may see it, and which nav it belongs
to - so the format decision is shared and should be taken once.

# Part 1: who may see an item

## The cache, which the engine already handles - for some pages

**Navigation is baked into every render, and the rendered page is cached per
URL, not per viewer.** So the obvious implementation - filter the nav while
rendering, according to the current user's groups - would poison a shared cache
with one viewer's navigation.

The engine already refuses that trap, and says so. In `lazysite-processor.pl`:

> A protected page is never served from - nor written to - the global .html
> cache. [...] caching it would (a) serve a stale menu that ignores a
> just-granted capability until the cache is busted [...] and (b) leak one
> user's capability-gated menu to another via the shared cache. Only
> `auth: none` (public) stays cacheable.

So for any page carrying an auth level or a group restriction, per-viewer nav is
already safe: those pages are not cached at all. **Part 1 is nearly free on
gated pages.**

The cost lands somewhere else, and it is the real design question: putting a
gated nav item on a PUBLIC page makes that page viewer-dependent, and public
pages are exactly the ones the cache exists for. An intranet link in the main
nav of a public homepage would, under the current policy, make the homepage
uncacheable for everyone.

## Partial caching, and whether it means a PWA

It does not mean a PWA. The reason is a fact about how pages are served, which
is worth stating because it is the thing that decides it:

**Once `lazysite/auth/acls.json` exists, the front end routes requests through
the CGI rather than serving rendered HTML directly.** The Apache template sends
any existing file, any clean URL with an `.html`/`.shtml` sibling, and the site
root through `lazysite-auth.pl`. The web server is not handing out cached HTML
behind the engine's back on such a site.

That is what makes fragment composition possible: the request is already in
Perl on a cache hit. So the cached artefact can become **a shell with a hole**
rather than a finished page - the expensive work (markdown, layout, theme)
cached once and shared by everyone, the cheap viewer-dependent fragment
composed per request. The cache stays one copy per URL; only the hole varies.

Three consequences to accept up front:

1. **The cache stops being servable as a static file.** Today a rendered page
   COULD be served directly by the front end on a site with no ACLs (the
   template has rules that do exactly that). A shell-with-holes cannot be, so
   either the feature requires auth to be configured, or those rewrite rules
   must route through the processor too.
2. **Every request pays assembly.** On a site with ACLs that cost is already
   being paid - the request is in the CGI regardless - so the marginal cost is
   a substitution rather than a re-render. On a site without, it is new cost.
3. **The hole must be small and clearly bounded.** A shell with one nav-shaped
   hole is a cache. A shell with holes everywhere is a template being rendered
   per request, which is the thing the cache exists to avoid.

The PWA answer - ship a static shell and fetch everything else client-side - is
the alternative if the engine ever needs to serve rendered pages statically at
the front end. It buys CDN-ability at the cost of requiring JavaScript for
navigation, which is a heavy price for a site engine whose output should read
without it. Fragment composition keeps the pages working with JavaScript off.

**Recommendation:** fragment composition, not a PWA, and not per-viewer cache
keys. Per-viewer keys fragment the cache across the whole site for a feature
used on a few items, which is the objection the release manager raised and it
is correct.

## Hiding a link is not access control

A hidden nav item must not be the only thing standing between a visitor and the
page. The page's own ACL is what protects it; nav visibility decides whether
someone is *invited*, not whether they are *allowed*. If the two disagree the
ACL wins, and it should - otherwise this becomes security theatre that reads
like a permission system.

Worth stating in the UI where the gating is set, because "only this group can
see this link" is a sentence an operator will reasonably read as protection.

The engine already has the vocabulary: an ACL naming principals, `_acl_allows`,
and the group model. A nav item's gate should name principals the same way a
file's ACL does, so the words mean one thing across the product.

# Part 2: named navs, placed anywhere

## Half of this exists

Per-domain nav files are already real: a domain row carries `nav_file`, and
`Lazysite::Manager::Nav::resolved_nav_files` maps each nav file to the hosts
that use it (SM443). The engine therefore already resolves *more than one nav
per instance*.

What it cannot do is **name** them or **place** them. A nav is chosen by which
host you are on, not by the builder saying "put the intranet nav here". The
request is to promote that from a per-domain override to a first-class object.

## Shape

- A nav has a **name** (`main`, `intranet`, `footer`).
- It can be **included** where the builder wants, rather than only in the
  layout's one nav slot.
- The name **is** the styling hook - `nav-intranet` as a class on the rendered
  element - so a variation is a stylesheet change, not a template fork. This
  also means nav names are part of the site's public surface, and renaming one
  breaks its CSS; worth saying so in the editor.
- Items carry their own visibility, per Part 1.

## What it collides with

[[SM349]] - the shipped layouts discard the site navigation. Layouts that drop
the nav today would drop named navs too, and a builder placing `intranet`
somewhere the layout ignores gets silence rather than an error. SM349 wants
settling first or alongside, or this lands on top of a known gap.

# Part 3: the editor

Per the release manager, and consistent with what the manager already does
elsewhere:

- The existing nav dropdown becomes a **list of navs**, with **add** beside it.
- Each nav line gets an **expander below it, styled as the Files expander** -
  the same chevron, `mg-perms-card`, and the shared `mgRights` chips extracted
  in [[SM678]] and used for a data table in [[SM687]].
- The expander sets **source, destination, and users/groups** for that item.

The third of those is the same control as a file's ACL and a table's ACL, which
is the argument for doing it this way rather than inventing a nav-specific
permissions widget: three objects, one editor, one thing for an operator to
learn. `mgRights` is already shared and already has a second caller, so a third
is cheap.

# Ordering

1. Decide the caching answer for Part 1. Nothing else can be built safely first.
2. Decide the format: `nav.conf` gains per-item fields, or navs move to a
   structured file. Both halves depend on it, and a format taken twice is a
   migration taken twice.
3. Part 2's naming and placement, with SM349 settled.
4. The editor, which is the cheapest part and reuses controls that exist.

# Related

[[SM349]] (layouts discard the nav), SM443 (per-domain nav files - the half
that exists), SM536 (nav is part of the cache validity check, which is where
the trap lives), [[SM678]] (the shared rights editor), [[SM687]] (its second
caller, and the same expander pattern), SM635 (a thing that is hidden should
say it is hidden, where the operator is looking).

# Not started
