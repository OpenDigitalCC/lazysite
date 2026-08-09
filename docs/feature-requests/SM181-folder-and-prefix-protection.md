---
title: "SM181 - Folder / URL-prefix protection (hold a section back, release in one go)"
subtitle: "Gate a whole subtree behind auth or as a draft, without touching every page - and publish it atomically"
brand: plain
status: partial
status-note: "PARTIAL 2026-08-09 (unreleased on main): the AUTH-GATE half is built, and NOT by the mechanism proposed here. SM223's operator decision put folder scope in the EXISTING acls.json rather than a new prefix list in lazysite.conf, so this became small: the processor already consulted a folder ACL entry for static files, and now consults it for PAGES too. One entry gates a section's pages and its assets together, which also CLOSES the static-asset caveat this filing left open (option 3, reached by a different route). A page inside a gated section cannot opt out with auth: none - the longest PATH match wins, not the mechanism. Deleting the entry publishes the subtree atomically. A gated page is never written to the shared HTML cache. t/integration/36 covers it and fails on the pre-SM181 processor for exactly the page subtests. NOT BUILT: the DRAFT policy (404 to the public rather than a login bounce, absent from sitemap and search, previewable by an editor) - which this filing argues is the better fit for 'not yet ready for publication', so the remaining half is the one it led with. Also not built: the Protected sections manager panel; the rule is hand-written JSON or set through the existing per-file ACL tools."
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

## Built 2026-08-09: the auth-gate half, on the ACL store

**Mechanism A below was not chosen, and the reason is worth recording.** SM223
asked the operator the same question - where does folder scope live - and the
answer was the existing `lazysite/auth/acls.json`, not a new prefix list in
`lazysite.conf`. One store, because two mechanisms for "this path is protected"
would give operators two ways to believe they are protected and only one of them
would cover static files.

That made this small. The processor already consulted a folder ACL entry for
source-less statics; it now consults it for pages as well, before `check_auth`:

```json
{ "upcoming": { "read": ["@editors"] } }
```

- every page under `/upcoming/` requires an editor, with no per-page front matter;
- so does every asset in it - which **closes the static-asset caveat below**,
  reaching option 3's outcome by a different route;
- a page inside the section carrying `auth: none` does not escape the gate. The
  longest PATH match wins, not the mechanism that declared it. A section you can
  hold back only if every page inside agrees is not a section gate;
- a gated page is never written to the shared HTML cache, so a render for a
  permitted user cannot be served to the next anonymous visitor;
- **deleting the entry publishes the subtree atomically**, which is the operator's
  original ask.

### What is still open

**The draft policy.** This filing leads with draft-hide - 404 to the public,
absent from the sitemap and search, previewable by an editor - and argues it is
the better fit for "not yet ready for publication", because a coming-soon section
should not answer 403s at guessable URLs. What is built is the auth-gate: a
protected page bounces to login, which reveals that the URL exists. So the half
this filing recommended is the half still to do.

**The manager panel.** No "Protected sections" UI: the rule is written as JSON,
or through the existing per-file ACL tools. There is no one-click *Publish
section* - the atomic release works, but an operator performs it by deleting an
entry rather than pressing a button.

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

## The static-asset caveat - CLOSED 2026-08-09

Answered by SM223, and by option 3 rather than the recommended option 1: a
protected asset is routed through the engine and gated by the same ACL entry as
the pages around it. The section below is kept as the reasoning that led there.



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
