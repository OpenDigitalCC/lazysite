---
id: SM1284
title: "SM1284: the /docs manual is the engine's"
subtitle: "The agent briefings and the manual they link into were starter content in each site's docroot, so cleaning a site up for launch put the instructions agents are sent to at risk. The whole manual now ships in the engine tree, is refreshed by every upgrade, and serves at /docs/ whenever the site has no page of its own there."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-21
raised-by: "the owner, filed from the theunited.community setup (inbox 2026-10-21-agent-briefings-apart-from-starter-boilerplate.md); rulings 4, 27, 32, 34 and 35"
area: processor
status-note: "SHIPPED (PENDING) on n734: the manual ships in {LAZYSITE}/templates/docs and serves when the site has no page at the path (site, engine, 404); access rules and section themes see its served path; engine_docs_public lists it as the site's; check warns on a shadowing copy; the upgrade drops unmodified docroot copies. t/tools/280, t/unit/processor/160, t/lint/290."
---

# What was asked

The owner, setting up theunited.community for real content, wanted the starter
boilerplate gone and the agent briefings kept. Both lived in the docroot's `/docs/`.
The briefings link to about 20 further docs pages, so keeping them meant building a
keep list of 30 pages and deleting 93 files. On theunited.fund the whole of `/docs/`
had gone in August, briefings included, though the partner brief points at them.

The release manager ruled:

- **4:** the agent briefings, and the docs they link to, are served by the engine from
  outside the docroot, versioned with it and refreshed by upgrades.
- **27:** a site's own edited page at a briefing path wins, and `lazysite check` warns
  that it shadows the engine's newer version. An unmodified starter copy is removed at
  upgrade.
- **32:** the WHOLE `/docs` manual is the engine's, not only the briefings' link set.
- **34:** at the upgrade that ships this, unmodified `/docs` copies are removed and
  edited ones are kept and warned. Starter pages are kept.
- **35:** the engine's docs stay out of a site's search, sitemap, feeds and `llms.txt`
  unless a per-site setting puts them in. lazysite.io will set it.

# What shipped

- **Where the manual lives.** `starter/docs/` moved to `starter/lazysite/templates/docs/`.
  It installs to `{LAZYSITE}/templates/docs/`, beside SM201's system pages: code
  bucket, refreshed every upgrade, DAV-blocklisted with the rest of the engine tree,
  and outside the docroot on an SM293 layout. It is not starter content, so a site
  installed `--no-starter` has it.
- **How it serves** (`lazysite-processor.pl`, `_engine_doc_md`):
  - **Order.** For a `/docs/` path, the site's own page wins. That covers its content
    root, its private store and a `.url` page. Then the engine's page, then 404.
    `/docs/x` names `x.md`, or `x/index.md` for a section, since the docs link to both.
  - **Cache.** The render caches in a host slot under the engine's cache (`_engine` for
    the primary host), so serving the manual puts no `docs/` tree of `.html` back into
    a docroot its owner cleared. Every existing cache sweep already reaches the slots.
    `write_html` accepts that slot on an SM293 layout, where it is outside the docroot.
  - **Access rules.** `_content_rel` names an engine page by the path it serves at. An
    access rule, address list, draft section or section theme over `docs/` governs it
    as it would the site's own copy. A rule at `/` still covers it on an SM293 layout,
    where no docroot prefix would match.
- **Listings** (`registries.pm`):
  - **The manual's own scans** (the features index is `scan:/docs/features/...`) see
    the engine tree, so an index is complete on a site with no docs copy.
  - **A site page's scans** (the search index is `scan:/**/*.md`) and the registries
    (sitemap, feeds, `llms.txt`) include the engine's pages only when
    `engine_docs_public: true`.
  - **Either way the site's copy at a path is the one listed**, once, at its URL.
  - **Out of the management tree.** A recursive scan no longer walks into the
  `lazysite/` management tree. On a site whose engine tree is inside the docroot,
  `scan:/**/*.md` had listed the system pages at `/lazysite/templates/...` URLs, and
  would have listed the whole manual there. `scan_pages` already refused that tree.
- **describe_capabilities** indexes the manual from the engine tree and the docroot,
  the site's copy winning, so a site that cleared `docs/` still answers with the
  whole manual.
- **`lazysite check`** warns for each site page at a `/docs` path whose bytes differ
  from the engine's. The warning says it shadows a newer version, and that deleting
  it serves the engine's. A byte-identical copy is not warned.
- **The upgrade** needs no new step. The old `{DOCROOT}/docs/` destinations leave the
  manifest, and install.pl's plan handles a file that has left it:
  - a copy whose checksum still matches the install state is removed, with its
    cached renders;
  - an edited copy is kept, and named as `orphan (edited post-install, left in place)`.

  Nothing else is touched, and a second run changes nothing.
- **Lint 290** holds that every `/docs` link in the manual names a page of the
  manual. It also checks the `/docs` paths the pointers name: the partner brief, the
  shipped `.well-known/ai-partner`, the MCP instructions and tool descriptions, and
  describe_capabilities. Lint 118's docroot heuristic no longer counts a repo path
  under `starter/lazysite/` as a docroot.
- **Docs:** the manual's configuration page (a new section, "The /docs manual", with
  how an operator overrides a page) and the `engine_docs_public` key in configuration
  and reference. The manual's index says it is the engine's. UPGRADE.md says what the
  upgrade does to `docs/`.

# Tests

- **t/tools/280** (new), against real installs:
  - a fresh site and a `--no-starter` site have no `docs/` in the docroot, and serve
    the briefings, the reference, forms and the docs index. The features index lists
    the engine's features pages;
  - a site copy wins and the check warns, naming it, while an identical copy is not
    warned;
  - deleting the site's `docs/` leaves the page served, and serving it creates no
    `docs/`;
  - an upgrade from a state that shipped the manual into the docroot:
    - removes an unmodified briefing and an unmodified manual page, with the
      briefing's cached render;
    - keeps an edited page and names it;
    - leaves the site's own docs page and a starter page alone;
    - is unchanged on a second run.
- **t/unit/processor/160** (new): by default the sitemap and a site page's scan list
  no engine page, and the manual's own index does. With `engine_docs_public: true`
  both list it. A site copy at the same path is listed once, as the site's.
- **t/lint/290** (new): every `/docs` link in the manual and its pointers resolves.
