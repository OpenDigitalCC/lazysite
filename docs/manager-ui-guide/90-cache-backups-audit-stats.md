---
title: "Cache, Backups, Audit log, Visitor statistics"
brand: plain
---

# Cache

Governing capability: `manage_config`.

Where
: System -> Cache

Do
: List the cached pages, invalidate one, then invalidate everything. Reload the
  public site between each.

Expect
: The listing shows what is cached per host. Invalidating removes the generated
  file so the next request re-renders. Per-host copies go with it - a
  multi-domain site that clears only the primary's cache is a bug this check
  exists to find.

Negative
: Cache invalidation is a read-ish action but still capability-gated; confirm an
  under-privileged account cannot clear it.

# Backups

Governing capability: `manage_config`.

## Take and restore a snapshot

Where
: System -> Backups

Do
: Create a snapshot, change a page, restore, and check the page.

Expect
: The list shows each artefact with its size and its `sha256`. A restore takes a
  **pre-restore snapshot first**, so the restore is itself reversible, and
  reports how many cached pages it cleared.

Negative
: Two snapshots taken in the same second must not collide into one file. Take
  several in quick succession and confirm you get several.

## Apply a site package

Where
: System -> Backups -> Apply

Do
: Apply a package to a target domain that already has content. Change the target
  in the dropdown and watch the preview.

Expect
: Before you confirm, the panel tells you how many files are **new** and how many
  would be **overwritten**, whether the bundled layout and theme are already
  installed, and whether the target's DNS and TLS are pointed yet. The counts
  change when you change the target - a figure that does not move is a cached
  first answer.

Negative
: A target whose DNS is not pointed shows a warning and the apply is **still
  allowed** - staging content before a cutover is a legitimate deliberate act.

## Keep your own presentation

Where
: System -> Backups -> Apply -> Presentation

Do
: Tick **keep this site's theme**, apply, and inspect the target.

Expect
: The package's content arrives; the target's theme is untouched. Leave
  everything unticked and the previous behaviour is unchanged - an operator who
  ignores this control gets exactly what they got before.

## Undo an apply

Where
: the bar that appears after an apply

Do
: Apply, then press **Undo**.

Expect
: The site returns to its pre-apply state, and the undo takes its own snapshot
  first. The snapshot being restored is named in the confirmation, so you can see
  which one it is.

# Audit log

Governing capability: `audit`.

Where
: System -> Audit log

Do
: Perform a grant, a delete and a failed sign-in, then read the trail.

Expect
: Every material action - state changes and security grants - records who, what,
  **to what**, when, from where and the outcome. Reads and browsing are not
  audited; the access log covers those and the two must not overlap.

Negative
: A delegate holding `create_sub_users` but not `audit` sees only the accounts
  beneath them, not the whole trail.

# Visitor statistics

Present only when the stats plugin is enabled.

Where
: System -> Visitor statistics

Do
: Visit the public site from a normal browser, then with a
  `lazysite-agent/<partner-id>` user agent.

Expect
: The human visit is counted; the agent visit is not. Agent traffic staying out
  of visitor analytics is the point - a screenshot pass should not look like an
  audience.

Negative
: Without the plugin the menu item is absent entirely, not present and empty.
