---
id: SM1286
title: "SM1286: lazysite starter lists the starter pages and removes the unmodified ones"
subtitle: "A site keeps the starter pages it already has when the default changes (SM1285). `lazysite starter --list` names them as unmodified or edited by provenance, and `--remove-unmodified` (with --dry-run) removes the ones the site never edited, with their cached renders, and never an edited one."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-23
raised-by: "the release manager, ruling 34 (2026-10-23)"
area: install
status-note: "SHIPPED (PENDING) on n734: lazysite starter --docroot D (--list | --remove-unmodified [--dry-run]) over install.pl --list-starter / --remove-starter; the manifest's starter flag, provenance stamp and recorded or shipped checksum; refuses root to remove; audited; names menu entries left linking a removed page. t/tools/281."
---

# What was asked

Ruling 34 (2026-10-23): at the upgrade that ships SM1284 and SM1285, the starter pages
already on a site are KEPT. A new command lists the unmodified starter pages or removes
them on request. It runs as the site user, uses provenance, has a `--dry-run`, and never
removes an edited page. The supervisor asked for it to be named per the CLI's
conventions.

# What shipped

- **`lazysite starter --docroot D (--list | --remove-unmodified [--dry-run])`**, with
  `--installdir`, as the other single-site verbs take it.
  - **Delegation.** The verb drives `install.pl --list-starter` /
    `--remove-starter`, which holds the manifest, the install state and the page
    removal an upgrade uses. That is the same split as `backups` over
    `--list-backups`.
  - **Root.** It refuses root to remove, and listing reads only.
- **Which pages:** the manifest's own `starter` flag, from classification.json's
  `starter_content`. That is exactly what `--starter` lays, and never forgot, logout or
  the search pages.
- **Unmodified is provenance, as ADR 0004 defines it.** The page still carries
  `provenance: lazysite-starter`, and its bytes match the checksum the install state
  recorded for it, or the one this release ships. So a site whose state is lost is
  still answered. Anything else is edited and is never removed.
- **The removal:**
  - **What goes:** each unmodified page, its `.html` render beside it and its
    alias-host copies. This uses `remove_page_file`, now shared with an upgrade's
    `remove` step.
  - **What is told:** it prints what it removed and what it kept, and writes a
    `starter-removed` line to the audit log.
  - **The menu** is the operator's, so a `nav.conf` entry left linking a removed page
    is named rather than edited.
  - **A second run** removes nothing.
  - **A later reinstall or upgrade** does not bring the pages back. The install state
    still tracks them, and a tracked file the site deleted is preserved as deleted.
- **Docs:** the CLI usage and POD, install.pl's usage, the manual's install page and
  UPGRADE.md.

# Tests

- **t/tools/281** (new), against a real `provision --starter`:
  - **`--list`:** names the five unmodified pages and the edited one, leaves out
    forgot, logout, the search pages and the site's own page, and changes nothing;
  - **`--dry-run`** says what would go, and removes nothing;
  - **root is refused** the removal;
  - **the removal:**
    - takes the five unmodified pages and a cached render;
    - keeps the edited page and the pages a site needs;
    - leaves the site's own page and the manual alone;
    - names the menu entry left linking a removed page;
    - is audited;
  - **a second run** removes nothing, and a reinstall brings none back;
  - **with the install state deleted,** an unchanged page is still unmodified and an
    edited one edited.

  With the unmodified-or-edited test sabotaged to call every page unmodified, five of
  its assertions fail.
