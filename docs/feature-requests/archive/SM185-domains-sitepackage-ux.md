---
title: "SM185 - Domains + site-package UX pass (default-site framing, self-contained export, language)"
subtitle: "Frame Domains as additional-domains-only; export the default site without the domains feature; carry language in packages; declutter the row actions"
brand: plain
status: shipped
status-note: "v1 built on claude/manager-domains-ux for 0.9.7 and complete: lang/lang_group in packages; default-site export (manage_content) on Backups; Domains actions dropdown + default row removed + copy; single Services heading; all covered by t/unit/manager/35-site-package.t. No follow-up was ever tracked against SM185, so it is marked shipped. One ADJACENT enhancement remains un-built in this area (NOT part of SM185): first-class domain aliases (several hosts -> one content_root, exposed as a domain-alias-add action + an alias_of marker in the Domains list). The engine already supports a shared content_root; only the first-class UI/API affordance is missing. Captured from the earlier SM155 plan; open a fresh item if wanted."
---

# SM185 - Domains + site-package UX pass

Field feedback on the 0.9.5/0.9.6 domains + site-package surfaces. A cohesive
polish pass, UI-plus-small-backend, no migration.

## What was built

1. **Language travels with a site package** (SM158 gap). The package manifest
   carried 7 presentation keys but not `lang`/`lang_group` (SM179), so an
   exported/migrated site lost its language. Both keys are now packaged and
   written to the target on apply - a package is a faithful copy of the source's
   presentation, and language is part of it.

2. **The default/primary site is exportable without the domains feature.** Site
   packages previously came only from the Domains page (`manage_domains`), so a
   site that does not use additional domains could not package/hand off its own
   site from the UI. A new **Export this site** on the Backups > Site packages
   panel calls `site-export-primary` (`manage_content`) and packages the default
   site's content (the docroot root, **excluding** `lazysite/` infra + secrets
   and every other domain's content root). A scope-confined editor may not export
   the whole default site.

3. **Domains page is about ADDITIONAL domains.** The default/primary site is no
   longer listed there (it lives in Site settings); the page intro is reframed to
   "additional domains you serve from this one instance." Per-row actions
   (Edit / Preview / Check / Export / Delete) are folded into a per-row **Actions
   dropdown** (inline-expanding, so it is never clipped by the table's
   overflow-x box) instead of a crowded button strip.

4. **Site settings: one Services heading.** The service killswitch toggles each
   re-emitted the "Services" section title; the form now emits a group heading
   only when the group changes, so they sit under a single heading.

## Note: "the Domains feature disappeared"

Domains is not a toggleable plugin - it is a manager area gated on the
`manage_domains` capability (nav link in the manager layout). SM160 carved
`manage_domains` out of `manage_config`, so an operator who held only
`manage_config` stopped seeing the Domains area. It is operator-recoverable:
grant `manage_domains` to the relevant group on the Groups page. This is
expected, not a regression; the copy pass makes the additional-domains framing
clearer.

## Tests

`t/unit/manager/35-site-package.t`: language is packaged and applied to the
target; the default site packages from the docroot root while excluding
`lazysite/` and other domains' content. New action classified in the cap-gate,
audit and write-path guards.
