---
title: "SM193 - Site-package migration completeness (download, target identity, asset mirror)"
subtitle: "create/inspect/upload/apply work end-to-end for demo handoff; three gaps break agent-driven migration to a NEW domain"
brand: plain
status: candidate
status-note: "ALL THREE GAPS IMPLEMENTED on claude/batch-site-integrity (2026-07-23). Gap 1: a site-backup-download control-API action (manage_domains, so token-accessible; name-confined to lazysite-site-*, scope-confined to the package content root) streams a site package, completing the agent create->download->upload->apply migration loop; added to the manage_domains api unlocks + %need + channel gate; test in 46-site-package-ui.t. Gap 2 (identity): apply_and_configure keeps the TARGET domain's site_url/site_name by default (a migration), and only stamps the package's with adopt_identity => 1 (--adopt-source-identity handoff); the manager-api threads req.adopt_identity. Gap 3 (asset mirror): package_apply now mirrors the installed layout's theme assets to /lazysite-assets/ (via Themes::_mirror_theme_assets) so an applied site renders styled immediately. Tests in 35-site-package.t. DEFERRED gap 1: a token-client site-backup-download action (manage_domains, confined to the lazysite-site-* namespace) - a new download action + %need entry, larger and independent; token clients can still create/upload/apply. Field end-to-end test 2026-07-21."
---

# SM193 - Site-package migration completeness

## Why

An end-to-end test of site-package migration (SM183 / SM158) from an edge instance
to lazysite.io confirmed the core works well: `site-backup-create` packaged the
domain exactly as designed (content root + nav mode + the layout pruned to the
active theme, ~2.2 MB, a sensible manifest); `site-backup-inspect` validated before
applying; `site-backup-upload` / `apply` installed the layout, placed content into
the target's registered content root, and took a safety pre-restore snapshot
before touching anything (a genuinely nice touch). Three gaps break the
AGENT-DRIVEN, NEW-DOMAIN migration path - each was worked around by hand in the
test.

## Gap 1 - a token client cannot DOWNLOAD a package

A token (agent) client can create, upload and apply a package but NOT download
one: `backup-download` is excluded from the token action set (`%need`), so
agent-driven cross-instance migration breaks in the middle - the agent packages on
the source but cannot fetch the archive to upload to the target. (Worked around by
re-authoring the package from a canonical local tree, which also proved the package
format interoperates perfectly with hand-built archives.)

Fix: a dedicated `site-backup-download` control-API action, gated on
`manage_domains` and confined to the `lazysite-site-*` namespace - so it exposes
only site packages, not the `manage_config` full-system backups that
`backup-download` covers. Add it to the token `%need` map and the MCP surface.

## Gap 2 - apply stamps the SOURCE's site_url / site_name onto the target

`apply` writes the source package's `site_url` and `site_name` onto the target
domain. That is right for the demo-handoff case (clone a site as-is) but wrong for
migration to a NEW domain - it would set the target's URL/name to the source's
(e.g. a partner's URL stamped with the provider's). (Worked around by authoring
target-correct manifest keys before applying.)

Fix: on apply, PREFER the target domain's already-registered `site_url` /
`site_name` over the package's, or offer an explicit flag (e.g.
keep-target-identity vs adopt-source-identity) so handoff and migration are a
deliberate choice. The genuinely portable presentation keys (theme / layout / nav)
still come from the package.

## Gap 3 - apply installs the layout but not its asset mirror

`apply` installs the layout but not its `/lazysite-assets/` mirror, so an imported
site renders UNSTYLED until a later activation or hand-mirroring - the same
mirror-at-activation gotcha in new clothing. (Worked around by hand-creating the
mirror, all four theme assets.)

Fix: `apply` should mirror the layout's assets on install (the same mirror step
layout activation performs), so an applied site renders styled immediately. This
is the migration side of the standing mirror-at-install rule.

## Not blocking; each has a manual workaround

The feature is usable for the demo-handoff case today. These three close the
agent-driven, new-domain migration path so it works without hand-stitching.

Related: SM183 (site-package UI), SM158 (site packages), the layout
mirror-at-activation behaviour, and the SM183 follow-ups already tracked (dry-run
diff, rollback + MCP `site_apply` parity, target-readiness check, integrity sha,
presentation-key remap - Gap 2 here makes the presentation-key remap concrete).
