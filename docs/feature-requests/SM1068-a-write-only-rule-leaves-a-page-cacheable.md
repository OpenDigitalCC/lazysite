---
id: SM1068
title: "SM1068: a write-only rule leaves a page cacheable, and the rule store is decoded once per change"
subtitle: "A rule that only restricts writing made every page under it per-viewer: never cached, no-store, out of every registry. And the processor decoded acls.json on every request, and again on every draft check. Ruled: only a read list or a draft governs."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-13
raised-by: inbox, 2026-10-13 "A write-only ACL rule marks every page under it as per-viewer"
area: processor
status-note: "SHIPPED (PENDING), n561: _acl_governed and _acl_governing_key ask by audience ('see': a read list or draft); _acl_map is the one reader of acls.json, kept across requests on (path, mtime, size, inode, ctime); the shared page cache takes only a render made for no viewer. t/integration/236-239, t/integration/74, t/unit/processor/127, t/lint/259."
---

# The report

A news site with 1,745 posts and 1,779 rules (one per post naming its author,
editors and sysops as writers, plus `/post` and `/`; no read list anywhere) was
measured at 0.71 s a post against 0.24 s with the store emptied, and every post
answered `Cache-Control: no-store, private`. Two causes, both in the processor:

1. `_acl_governed` ended with `ref( _acl_entry_for( $map, $rel ) ) eq 'HASH'`
   and passed no mode, so ANY entry governing the path counted - a rule that
   only restricts writing included. The caller then set `$auth_protected`:
   per-identity, never served from or written to the shared render cache,
   no-store on output. The `/` rule alone did that to every page and static.
2. The store was opened and decoded on every request (`$ACL_MAP_CACHE` lasts
   one request), while `Lazysite::Auth::Acl::load_acls` keeps a copy keyed on
   path, mtime and size.

# Ruling (2026-10-13)

The release manager ruled, in these words: "Read/draft only: only rules that
change what a viewer sees (a `read` list, or `draft`) govern a page. A
write-only rule no longer makes a page per-viewer or uncacheable, and no longer
leaves it out of scans and registries. Read lists and drafts behave exactly as
now."

# Reproduced first

The report's check, on a site with one write-only rule on `/`, requesting `/`
twice: before the fix both answers were `no-store, private` and full renders.
t/integration/236 plants a marker in the cached file to tell a cache hit from a
render; with `_acl_governed` asking with no mode (sabotage S1) it is red.

# The fix

`lazysite-processor/acl.pm`:

- `_acl_entry_for` gains the mode `'see'`: an entry carrying a non-empty `read`
  list or `draft`. `_acl_governed` and `_acl_governing_key` ask with it.
- `_acl_map` is the one reader of `acls.json`. `_acl_allows_read`,
  `_acl_is_draft`, `_acl_governed` and `_acl_governing_key` all go through it.
  It returns the request's answer (`$ACL_MAP_CACHE`, cleared per request by
  SM973) and, under that, a process-wide copy keyed on path, mtime, size, inode
  and ctime - load_acls's key plus the two that make a chmod or a rename-over a
  new key. A copy is kept only once the file's ctime is more than a second old,
  so two writes inside one second are never answered from the first. A store
  that does not decode is kept as a failure (closed), never as `{}` (SM1024); a
  store that will not open is never kept. The processor's render path stays
  module-free (ADR 0001), so this is the equivalent cache, not a call into
  Auth::Acl.
- `_acl_is_draft` decoded the store itself on every call, with no memo at all,
  so a registry rebuild decoded it once per page. It now shares `_acl_map`.

`lazysite-processor/pipeline.pm`: `process_md` writes the shared page cache
(and triggers the registry update) only for a render made for no viewer - see
the third security check.

# Every caller, and what it does now

| Where | What it decides | After SM1068 |
|---|---|---|
| `lazysite-processor.pl:1134` (`_acl_governed($gate_src)`, the .md or .url gate) | `$auth_protected`: page cache bypassed, no-store, private, `_protected` to the render | set only under a read list or draft |
| `lazysite-processor.pl:1160` (`_acl_governed($md_path)`) | the same, for a Markdown page | the same |
| `lazysite-processor.pl:1479` (static-HTML fallback, SM133) | no-store, private on a legacy `.html` | a write-only one answers `no-cache, must-revalidate` |
| `lazysite-processor/pipeline.pm:292` (`_static_cache_control`, the 200 and 304 of `_serve_content_static`) | `no-store` on a governed static | a write-only static takes `asset_max_age` or the revalidation default |
| `lazysite-processor/sources.pm:918` (`_registry_hidden`, called from `scan_pages` for sitemap, feeds, llms.txt) | out of every registry | write-only pages listed; read and draft stay out |
| `lazysite-processor/include.pm:169`, `:171` (`_acl_governing_key`, SM898) | a governed partial is included only from a page under the same rule | "same rule" is now the same read/draft rule: a partial under a write-only rule is public content and includes anywhere; a read or draft partial still only from its own section. Before, a site with a write rule per post refused every shared partial, since each post's own write rule was a different key |
| SM1024 fail-closed (`_acl_governed` 1, `_acl_governing_key` '*', `_acl_allows_read` 0) | a store that will not load governs and refuses everything | unchanged, through `_acl_map`; the failure is kept, never `{}` |

Not callers, and unchanged: `_scan_hidden` (a `scan:` list) asks
`_acl_allows_read` for the requester and `_acl_is_draft`, never `_acl_governed`,
so pages under a write-only rule were already in scans; `_acl_refused` (the
static and page gate) asks the same two. `lib/` has its own reader
(`Auth::Acl::gating_for`, read gating) and does not call these.

None of these widens what a viewer can see beyond the ruling: a page or partial
leaves the "governed" set only when no read list or draft covers it, and
`_acl_allows_read` already served such a path to anyone.

# Security checks

Each with a test, each test red under the matching sabotage.

1. **A page under a READ rule is never cached and never served to a reader the
   rule excludes** - with a write-only rule on `/` and on the page itself
   around it (SM268 H10's shape). The listed reader is served `no-store,
   private` and nothing is written to the page cache; anonymous afterwards is
   sent to log in; the page's owner, outside the read list, gets 403.
   t/integration/237, t/integration/236 (control).
2. **A draft is still hidden**: 404 to anonymous, a signed-in preview is
   no-store and uncached, and it is in no registry and no anonymous scan, also
   with a write-only rule of its own (SM981's shape). t/integration/237,
   t/unit/processor/127.
3. **A page under a write-only rule renders the same for every viewer.** What
   in a render depends on identity without a read rule: the stash's
   `authenticated`, `auth_user`, `auth_name`, `auth_email`, `auth_groups`,
   `editor` and `manager_caps`. The shipped chrome does not bake them in - the
   sign-in control is client-toggled (SM099 `auth_control`) and the admin bar,
   with its Edit link, is injected per response after the cache
   (`_inject_admin_bar_live`), as is the form token (SM252). But a layout that
   prints one does, and measured on main: a page with NO rule, rendered first
   for alice, served `WHO=alice EDITOR=1` from the cache to the next anonymous
   visitor. That is older than this change, and this change would have put it
   on exactly the pages whose first viewer is their author. So the shared cache
   now takes only a render made for no viewer: a signed-in viewer still gets a
   cache hit, and the next anonymous render fills the cache.
   t/integration/238 (a page with no rule, and one under a write-only rule).
4. **An undecodable or unreadable acls.json still fails closed** (SM1024):
   the gated page and a page no rule names are both refused, never cacheable,
   nothing written to the cache; a kept store made unreadable by chmod (mtime
   and size unchanged) is refused. t/integration/237, t/integration/239,
   t/integration/186.
5. **A private-store file is never served from the public path**: a read-gated
   page whose source is in the store is served to its reader with no render in
   the document root or the store, and refused to anonymous.
   t/integration/237.

Scans and registries: t/unit/processor/127 lists write-only pages in the
registry walk and an anonymous `scan:` and keeps read-restricted and draft pages
out of both; t/integration/74 now asserts that a manager COPY (born with an
owner-only rule) is in the sitemap, the finding that test named and left open.

# Measured

Fixture: 1,800 posts, one write rule each (`owner`, `write: [author, @editors,
@sysops]`), plus `/` writable by `@sysops`; no read list; 264,275-byte store;
the starter's four registry templates; a static `data.json`. Three anonymous
requests each, seconds, on this host. `tmp/n561-measure*.pl` in the worktree.

```datatable
columns: Request | Before (CGI) | After (CGI) | Before (pooled) | After (pooled)
widths: 3.2cm | 2.6cm | 2.6cm | 2.6cm | 2.6cm
---
post | 0.46 / 0.46 / 0.46 | 3.29 / 0.21 / 0.20 | 0.334 / 0.340 / 0.349 | 0.112 / 0.005 / 0.004
/ | 0.47 / 0.47 / 0.46 | 0.22 / 0.18 / 0.20 | 0.344 / 0.350 / 0.351 | 0.006 / 0.004 / 0.004
/data.json | 0.32 / 0.29 / 0.32 | 0.20 / 0.20 / 0.20 | 0.234 / 0.227 / 0.222 | 0.002 / 0.002 / 0.002
```

With the store emptied (`{}`), before: a post 0.17 to 0.23, `/` 0.12 to 0.22,
`data.json` 0.12 to 0.19 (CGI; an earlier run of the same fixture measured the
"before" column at 0.68 to 1.00, the host's load varies).

Cache-Control on a post: before `no-store, private`; after `no-cache,
must-revalidate` (a page with `ttl:` gets `public, max-age=N`). `data.json`:
before `no-store`, after `no-cache, must-revalidate`.

Two things the table shows that the fix does not remove:

- **A CGI request still decodes the store once** (after: 0.18 to 0.21 s a
  request, against 0.12 to 0.23 s with the store emptied): a one-shot process
  has no memory to keep a copy in. The copy pays off
  in a persistent worker (the pooled column), and every request is now one
  decode where it was two or more (`_acl_is_draft` decoded on each call). An
  on-disk decoded copy would take CGI to a stat; it would be a new file the
  read decision trusts, so it is not built here - for a ruling.
- **The first render after a registry goes stale pays the rebuild**: 3.29 s on
  the post above (2.86 s in a second run; 0.21 s with no registry templates;
  1.80 s with the store emptied). Before the fix the processor never rebuilt a
  registry on this site, since every render was per-viewer and wrote nothing.
  The rule lookups in the rebuild are a walk over every key per page (about 1 s
  of it at 1,800 rules); an ancestor lookup would remove that - not built here.

# Tests and sabotage

- t/integration/236 - the filing's check; a post with its own write rule; a
  static; the read-rule control.
- t/integration/237 - security checks 1, 2, 4, 5.
- t/integration/238 - security check 3.
- t/integration/239 - the store decoded once per change across requests in one
  process; a change seen on the next request; a same-second rewrite never
  answered from the kept copy; an undecodable store kept as a failure; a chmod
  on a kept store refused. The keep guard is tested with an injected clock.
- t/unit/processor/127 - the three predicates and both listings against one
  store holding every case.
- t/lint/259 - only `_acl_map` reads and decodes acls.json; the four readers go
  through it; the key and the guard; `_acl_governed` and `_acl_governing_key`
  ask with `'see'`.
- t/integration/74 - the copy is listed.

Sabotaged one at a time (backup in tmp/sab-bak/n561/, restored with cp and
checked with cmp), each red: S1 `_acl_governed` with no mode (236, 127, 74); S2
`_acl_governing_key` with no mode (127); S3 `'see'` without draft (237, 127); S4
a viewer render fills the cache (238); S5 no copy kept (239); S6 an undecodable
store kept as `{}` (239, 237); S7 the key without inode and ctime (239); S8
`_acl_is_draft` decoding on its own (259, 239).

# Related

SM223 (static gate), SM268 H10/H12/H13, SM287, SM898 (include confinement),
SM973 (pooled worker), SM981 (draft mode), SM1024 (fail closed everywhere),
SM099 (cache-safe sign-in control), SM252 (form token per response).
