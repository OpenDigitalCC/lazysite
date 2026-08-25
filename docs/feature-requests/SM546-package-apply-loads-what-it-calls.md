---
title: "SM546: package_apply loads what it calls"
subtitle: "package_apply calls Backups::verify_sha256 without loading Backups, so a fresh process applying a package dies with Undefined subroutine."
brand: plain
standard-margins: true
status: candidate
status-note: "FOUND 2026-08-25 by the backups structural review, PROVEN by probe tmp/bp-probe-apply-no-backups.t; class: operability; recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. SitePackage.pm 599 calls verify_sha256 with no use or require of Lazysite::Manager::Backups on that path; only package_create (400) and the snapshot branch of apply_and_configure (842) load it. A fresh process calling package_apply, or apply_and_configure with snapshot off, dies with Undefined subroutine. The MCP and tools/lazysite-site.pl import SitePackage only and are shielded solely because they never pass snapshot => 0. Fix from the report: use Lazysite::Manager::Backups () at the top of SitePackage; Backups does not load SitePackage, so there is no cycle."
---

# The finding

`Manager/SitePackage.pm 599` calls `verify_sha256` with no `use` or
`require` of `Lazysite::Manager::Backups` on that path. Only
`package_create` (`SitePackage.pm 400`) and the snapshot branch of
`apply_and_configure` (`SitePackage.pm 842`) load Backups.

The probe shows a fresh process calling `package_apply`, or
`apply_and_configure(snapshot => 0)`, dies with `Undefined subroutine`.
The MCP and `tools/lazysite-site.pl` import SitePackage only (both at
line 50) and are shielded solely because they never pass
`snapshot => 0`.

# Why it matters

Operability: whether an apply works depends on what some other code
happened to load earlier in the process. The first caller that takes the
snapshot-free path in a clean process gets a crash in place of a result.

# The proving test

NEW single assertion: `package_apply` from a fresh process returns a hash.

# Fix shape

`use Lazysite::Manager::Backups ()` at the top of SitePackage. Backups
does not load SitePackage, so there is no cycle.
