---
title: "SM181 - Folder / URL-prefix protection (hold a section back, release in one go)"
subtitle: "Gate a whole subtree behind auth or as a draft, without touching every page - and publish it atomically"
brand: plain
status: candidate
status-note: "proposed 2026-07-19, target 0.9.5. Extends the per-page auth: front-matter to folder/prefix scope. Content/engine feature; a static-asset caveat needs a decision."
---

# SM181 - Folder / URL-prefix protection

## Why

Access control today is either **per page** or **whole site**, with nothing in
between:

- **Per page** - a page's front-matter `auth: required` (or `auth: <level>`) plus
  optional `groups:` gates that one page (`lazysite-processor.pl` `check_auth`).
- **Whole site** - `auth_default:` in `lazysite.conf` sets a default level for
  every page.

There is no way to protect a **folder / URL prefix**. To hold back an unfinished
section (`/upcoming/`, a client area, a not-yet-launched product) an operator must
stamp `auth:` on *every* page in it, and to release it, unstamp every page - error
prone, and there is no atomic "publish the whole section now."

The operator's ask: protect a folder that is not yet ready for publication, then
release all of it in one go.

## Two policies (both wanted)

"Protect a folder" means one of two things; the design should offer both:

- **Auth-gate** - the subtree EXISTS publicly but requires login (a private
  client area). Public request -> 403 / redirect to `/login`. Reuses today's
  `auth: required` / `groups:` semantics at folder scope.
- **Draft / staging** - the subtree is HIDDEN until launch: 404 to the public
  (don't even reveal the URLs), excluded from the sitemap and site search,
  previewable only by an authenticated editor. Publish = flip one switch and the
  whole subtree goes live atomically.

For "not yet ready for publication," **draft-hide is usually the better fit** than
auth-gate (a "coming soon" section shouldn't answer 403s at guessable URLs or hint
at unreleased structure), so the proposal leads with draft but supports both.

## Mechanisms considered

### A - prefix rules (recommended)

A small ordered list of URL-prefix -> policy rules, in `lazysite.conf` (or a
dedicated `lazysite/access.conf`), e.g.:

```
protect: /upcoming/     = draft
protect: /clients/acme/ = group:acme
protect: /members/      = required
```

`check_auth` already prefix-matches (it special-cases `manager_path` and reads
`auth_default`); it gains a longest-prefix lookup against this list, resolving to
draft / required / group before falling back to the page's own `auth:` then
`auth_default`. **Release in one go = delete the one rule** (or the manager's
"Publish section" button removes it) and the whole subtree is public.

- *Pro:* one place lists every protected area; atomic release; group-gating;
  zero per-file edits; tiny engine change on an existing code path.
- *Con:* a new conf list + matcher; needs a manager panel so it isn't raw conf
  editing.

### B - folder marker file (alternative)

A marker in the content folder (e.g. a `_access` front-matter key on the folder
index, or a `lazysite/access/<path>` sidecar) declaring the subtree's policy; the
processor walks up to the nearest marker. Release = delete the marker or move the
folder out of the protected tree.

- *Pro:* the gate travels WITH the content (move the folder, move the gate);
  intuitive.
- *Con:* per-folder files; a tree-walk per request; must be excluded from being
  served; no single place to see all protected areas.

### C - index front-matter inheritance (weakest)

A folder `index.md`'s `auth:` cascades to children. Rejected as the primary
mechanism: not every folder has an index, and cascade-from-index is surprising.

## The static-asset caveat (needs a decision)

lazysite's auth runs in the **processor**, which serves rendered pages. Static
assets (images, downloads) in a protected folder are typically served **directly
by the web server** and bypass the processor entirely - so a draft page is hidden
but its `/upcoming/hero.png` may still be fetchable. Options:

1. **Accept page-only gating** - rendered pages are protected; assets are
   "protected by obscurity" (only linked from protected pages). Simplest;
   document the limit.
2. **Emit web-server deny rules** - the vhost generators
   (`lazysite-nginx-vhost` / `-apache-vhost`) grow a generated `location`/`Files`
   deny for each protected prefix, regenerated when the rules change. Fully
   protects assets; couples the feature to a vhost re-render.
3. **Route protected assets through the processor** - heavier; changes the
   serving path.

Recommend (1) for the first cut (it matches the draft/coming-soon use case, where
the risk is a stray asset URL, not a breach) with (2) as a follow-up for true
private areas.

## Manager UI

A "Protected sections" panel (on the Files or a new Access page): list the
prefixes + their policy (draft / login / group), add one by picking a folder,
and a one-click **Publish section** that removes the rule (the atomic release).
Draft sections also show a "preview as public" toggle for the editor.

## Acceptance

- A folder marked `draft` returns 404 to the public, is absent from the sitemap
  and search, and renders for an authenticated editor's preview.
- A folder marked `required` / `group:X` redirects the public to login / 403s a
  non-member, and serves members - for every page under it, with no per-page
  front-matter.
- "Publish section" (or removing the one rule) makes the entire subtree public
  atomically.
- The static-asset limitation is documented (or closed via option 2).
