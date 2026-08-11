---
title: "SM266 - Apply-confidence controls in the manager: dry-run, readiness, rollback button, remap override"
subtitle: "Applying a site package overwrites a site. The backend is now reversible and verifiable; what is missing is the four manager controls that let a human see what will happen before agreeing to it."
brand: plain
status: shipped
status-note: "BUILT on main (unreleased), all four controls. The two needing new backend are covered by t/unit/manager/60: package_inspect takes an optional TARGET and returns added-versus-overwritten counts plus the layout/theme disposition (opt-in, so existing callers do not pay for a tree walk), and apply_and_configure takes keep_presentation so an operator can take the package content and keep the target theme, layout or nav. Untouched means the previous behaviour, exactly. The other two are presentation over data that already existed: the readiness check calls the existing domain-check from the apply panel, and Undo routes through the SAME backup-restore the Backups list uses - no second restore path - so it inherits the pre-restore snapshot, the cache clear and the audit entry, and is itself undoable. THE FOUR PANELS ARE NOT SUITE-COVERED: docs/MANUAL-CHECKS.md carries the pass, steps 6-9. CARVED OUT of SM183 on 2026-08-09; SM183's backend half was already complete."
---

# SM266 - apply-confidence controls in the manager

## Why

Applying a site package overwrites a site's content. SM158 made the package
portable and SM183 made the operation safe: a snapshot is taken on every surface
before anything is written, its name comes back so it can be restored, and the
artefact carries a digest so a package that travelled between organisations can
be verified on arrival.

What none of that does is let a **human** see what an apply will do *before*
agreeing to it. The Backups page shows a manifest preview - source host, file
count, theme, layout, nav - and then a confirm button. Everything below is the
difference between "I have read the manifest" and "I know what this will change".

This is carved out of SM183 rather than left on it, because SM183's backend half
is finished and a filing that is half-done reads as neither.

## What is already true, so nobody rebuilds it

- **The snapshot exists and is named.** `apply_and_configure` takes it on every
  surface and returns `safety`. `action_backup_restore` restores it. The rollback
  round trip is tested end to end (`t/unit/manager/60`).
- **Integrity is published.** Every package and backup gets a `<name>.sha256`
  sidecar in `sha256sum -c` format, surfaced as `sha256` in `backup-list`.
- **Names no longer collide.** Two snapshots in the same second used to produce
  one file; a prompt rollback destroyed the artefact it was restoring from.

So each item below is presentation over data that already exists, except the
dry-run, which needs one new read-only comparison.

## The four controls

### 1. Dry-run content diff

Before applying, show what the package would **add** versus **overwrite** in the
target content root, and whether the bundled layout/theme is missing on the
target (so it would be installed) or already present (so it would be left alone).

The only item here needing new backend: a read-only comparison of the package's
`content/` against the target root. `package_inspect` already extracts the
manifest safely and can be extended to list members without applying.

### 2. Target-readiness check in the apply flow

Fold the existing domain **Check** (DNS, vhost, TLS, content root exists) into the
apply confirmation, so applying to a target whose DNS or TLS is not yet pointed is
a visible warning rather than a discovery afterwards.

No new backend - `domain-check` exists. This is calling it from the apply panel
and rendering the result.

DNS, TLS and vhost provisioning themselves stay the operator's job, as in SM158.

### 3. Undo apply

One button that restores the snapshot the apply took. The action and the name
both exist; what is missing is the affordance and the confirmation around it.

Worth stating what makes this safe to offer: restoring is itself snapshotted, so
an accidental undo is also reversible.

### 4. Presentation-key remap override

Apply rewrites the target domain's presentation keys. SM193 made the *identity*
keys (`site_url`, `site_name`) opt-in via `adopt_identity`, which was the
dangerous half. The rest - theme, layout, nav, content_root - are still applied
wholesale, and an operator who wants to keep the target's theme while taking the
package's content has no way to say so.

Show which keys will change, from what to what, and let the operator deselect.

## Why these four are one filing

They share a property that decides how they must be verified: **all four are
manager JavaScript**, and the repository has no browser harness. A green suite
says nothing about any of them - which is precisely what `docs/MANUAL-CHECKS.md`
exists to keep visible, and its *Manager UI JavaScript* section is the pass.

Grouping them means one manual pass covers the set, rather than four passes at
four different times.

## Acceptance

- An apply confirmation shows added-versus-overwritten counts, the layout/theme
  disposition, the target's readiness, and the presentation keys that will
  change, before the operator confirms.
- Deselecting a presentation key leaves the target's existing value.
- After an apply, one control restores the pre-apply snapshot, and says which
  snapshot it is restoring.
- `docs/MANUAL-CHECKS.md`'s manager-UI pass covers all four.

## Not in scope

- Anything on the backend safety path - it is done (see above).
- DNS / TLS / vhost provisioning (SM158's line, unchanged).
- Cross-organisation package **signing**. The digest proves a package arrived
  intact; it does not prove who made it. Tamper-evidence for a package crossing
  an organisational boundary is a separate question and not asked for yet.
