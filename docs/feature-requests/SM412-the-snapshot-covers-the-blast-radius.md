---
title: "SM412: the apply's safety snapshot scopes to the target"
subtitle: "On a multi-domain instance, site_apply to a content-rooted domain snapshotted the WHOLE docroot - including the primary domain's tree, which the calling account could not read and the apply would never touch. The refusal said permission denied; the cause was scope."
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED 2026-08-19, diagnosed in the field by the partner agent it blocked (edge2.explore, a content-rooted domain under the primary docroot). The failing pair was the tell: site_backup of edge2 scoped correctly and succeeded, while site_apply's safety snapshot resolved to the primary domain's web directory and was refused - same host, same account, 26 seconds apart, opposite results, because they were not resolving the same path. SM378's carried detail is what made the diagnosis possible from outside. FIX: action_backup_create gains an optional docroot-relative root; the apply passes its target content_root, so the snapshot covers exactly the blast radius of the operation it guards (package_apply writes only under that root). An empty root - the primary site - keeps the whole-content snapshot, which for that target IS the blast radius. 'full' refuses a scope by definition. The scope is validated like any path input, and the test's first version was WRONG in an instructive way: it asserted bare refusal of traversal inputs, which a deleted validation also produces (tar fails on a missing directory) - the case that matters is traversal to an EXISTING directory outside the docroot, which without validation SUCCEEDS and archives foreign content into a self-service-downloadable backup. The sabotage matrix caught it; the test now forces that exact case and asserts the refusal comes from validation. Peer's prediction confirmed by construction: any content-rooted domain reproduced it, the default site did not, because only a content-rooted target has a parent to resolve wrongly."
---

# The field evidence

    site_backup edge2    16:58:32Z   ok, 10,231 bytes    scopes to sites/edge2
    apply's snapshot     16:58:06Z   permission denied   resolves to the primary web dir

The permission denial was a consequence, not a cause: the account should never
have been asked to read that tree. `action_backup_create('prerestore')` tarred
from `$DOCROOT` unconditionally - correct for the primary site, wrong for every
content-rooted domain, and it fails precisely on the multi-domain instances the
site-package flow exists to serve.

# The rule

**A safety snapshot covers the blast radius of the operation it guards.**
`package_apply` writes only under the target `content_root`, so that subtree is
what the snapshot carries. Restore is an overlay extract, so a scoped archive
restores exactly its own subtree. The private store is not carried - apply
never writes there.

# Verification

`t/unit/manager/61`, five subtests against a real multi-domain fixture with a
real chmod-000 tree standing in for the unreadable primary: the field failure
reproduced unscoped; the scoped snapshot succeeding, carrying exactly the
target subtree, and restoring; the traversal-to-existing-directory case; the
blocked apply completing end to end; and the primary keeping its wide snapshot.
Three sabotages, all confirmed to bite - including one the first test version
missed, recorded in the status-note.
