---
id: SM1285
title: "SM1285: the starter pages are opt-in"
subtitle: "A new site no longer arrives with lazysite's demo and sample pages. It has the system pages, the site search, the engine's /docs manual and a minimal home page it replaces by writing its own; --starter adds the starter pages, on every way a site is provisioned."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-23
raised-by: "the release manager, ruling 33 (2026-10-23), from the owner's request on theunited.community"
area: install
status-note: "SHIPPED (PENDING) on n734: install.pl provisions without starter pages unless --starter (recorded, --no-starter accepted); the engine's minimal home serves / until index.md exists; the seeded nav drops the skipped pages; provision, hestia-domain, the Hestia deploy and Docker opt in. t/tools/95, t/unit/processor/161."
---

# What was asked

Ruling 33 (2026-10-23): new installs lay down NO starter pages unless `--starter` is
given, and `--no-starter` stays accepted as a no-op, so existing scripts work. This
applies to provision, install.pl, the Hestia integrator and its deploy, and the Docker
package. A fresh site has the system pages, the engine docs (SM1284) and a minimal home
page the owner replaces. The supervisor asked for the minimal home to be decided and
reported, and for the first-run and onboarding flows that point at starter pages to be
checked.

The ruling names four classes of page: system pages (the engine's, SM201),
documentation (the engine's, SM1284), starter pages (site content, opt-in), and the
site's own content.

# What shipped

- **install.pl:**
  - **`--starter`.** A `provision` without it lays no starter page and records
    `starter: none`, so a later reinstall or upgrade keeps to it.
  - **`--no-starter`** is accepted and means the same.
  - **A site with no recorded choice** was installed when the pages came by default,
    and keeps that behaviour.
  - **`--starter` on a site that declined them** lays the ones it has not got and drops
    the recorded `none`. Nothing removes a page a site has.
  - **The summary** says how many were skipped and that `--starter` installs them.
- **What a new site has without them:**
  - the system pages;
  - `forgot` and `logout`;
  - the site search (`search-index`, `search-results`, kept now beside forgot and
    logout as `starter_role: infrastructure`, since they list the site's own pages);
  - `assets/`, `.well-known/` and the manager;
  - the `/docs` manual.
- **The minimal home** is the engine's: `lazysite/templates/system/home.md`.
  - **Served** at `/` when the content root has no `index.md`, `.url` or private-store
    copy. The site's page wins from the moment it writes one.
  - **Not a system page.** A content-rooted domain without a home page gets the engine's
    minimal one, never the primary's.
  - **Content:** it says the site has no home page yet and how to write one. It links
    the manager, `/docs/` and the building-sites briefing.
  - **Like the manual,** it caches in the `_engine` slot. An access rule at `/` governs
    it, as it would the site's own `index.md`, on both layouts.
  - **Why the engine's, not a seeded page:** a seeded `index.md` would share its path
    with the starter's welcome page in the manifest. A page the engine serves never
    becomes content an upgrade must preserve, and it restores itself if the site
    deletes its home page.
- **The first-run flows:**
  - **The menu.** The seeded `nav.conf` links the demo, contact and members pages, so a
    site without them now gets the menu without those entries.
  - **`lazysite demo`** provisions its demo site with `--starter`, being the one that
    wants the demos.
  - **Onboarding and the system pages.** The partner brief, `.well-known/ai-partner`,
    the MCP instructions and the system pages link only to `/docs` and to themselves.
    The 402 page's demo link is to the payment-demo plugin, not a starter page.
- **Every way a site is provisioned:**
  - `lazysite provision --starter`;
  - `lazysite-hestia-domain add ... --starter`, passed to the provision it runs;
  - `lazysite-hestia-deploy.sh` and the Docker entrypoint, with `LAZYSITE_STARTER=1`
    on the first deploy or start;
  - the legacy Hestia template hook (`install-hestia.sh`) no longer seeds the starter's
    `index.md`.
- **Docs:**
  - the manual's install page ("What a new site has, and the starter pages");
  - the CLI usage and POD, and the `lazysite-hestia-domain` usage and POD;
  - the Docker README's environment table.

# Tests

- **t/tools/95** (rewritten), against real installs:
  - **A plain provision, and one with `--no-starter`:**
    - no starter page and no `docs/`, and the summary says so;
    - forgot, logout, the search pages, `assets/`, `.well-known/`, the manager and
      the manual are all there;
    - `/` serves the engine's minimal home, and a written `index.md` replaces it;
    - the seeded menu has no demo, contact or members entry;
    - the choice is recorded and survives a reinstall.
  - **`--starter`** lays every starter page and the full menu, and records no opt-out.
  - **A site with no recorded choice** keeps its starter pages through a reinstall.
- **t/unit/processor/161** (new): with the engine tree inside the docroot and beside it,
  a rule over `docs/` keeps the manual from an anonymous visitor, and a rule at `/`
  keeps both the manual and the minimal home. This also pins SM1284's access mapping.
  Reverting the mapping fails three of its six subtests.
