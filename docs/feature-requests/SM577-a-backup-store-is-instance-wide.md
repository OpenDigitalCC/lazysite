---
title: "SM577: a backup store is instance-wide, so deleting a backup is not scoped by site"
subtitle: "One instance serves many domains from one backups directory. A grant that may delete a backup on one site may delete the only copy of another site that was never offered up."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.33 as the delete half of SM578's fix, which is the same function - _package_scope_refusal governs site-backup-delete and site-backup-download alike, so a token partner can no longer delete a package belonging to another domain on the instance. WHAT IS NOT CHANGED, and is correct: an OPERATOR on a cookie session still reaches every domain's archives, because the backup store is instance-wide by SM151's design and the operator is the person who owns the instance. So 'may delete a backup' is still scoped by instance for the operator and is now scoped by grant for a partner, which is the distinction the filing asked for. THE TEST-SCOPING CONSEQUENCE STANDS UNCHANGED as guidance rather than code: a cross-principal backup probe must create the backup it deletes, never reuse an existing one, because the blast radius is a different site from the one under test. OBSERVED BY THE SITE AGENT 2026-08-25 in the audit trail's target facet on edge (archive names for providers.explore and edge2.explore, hosts that are not edge), marked by them as an observation rather than a finding because a facet proves a name was RECORDED, not that the archive is in the store now - and backup-list needs manage_domains, which they did not hold. VERIFIED FROM THE CODE the same day, which settles the mechanism without a live probe: SitePackage::package_create($host) resolves any configured domain of the instance through domains_list and writes lazysite-site-<safehost>-<ts>.tar.gz into _backups_dir() - the LOCAL instance's backups directory. So one site's backup store legitimately holds archives FOR other hosts on the same instance (SM151's one-instance-many-domains design), and the agent's reading was correct. STILL UNVERIFIED, deliberately: whether edge's store holds those archives right now; that is one backup-list call by someone holding manage_domains. TWO CONSEQUENCES. (1) TEST SCOPING: 'edge is a site nobody minds losing' is the wrong frame for any cross-principal backup-delete probe - the blast radius is a different site from the one under test. The safe shape is a backup CREATED for the test and deleted in the test, never an existing one: the throwaway-table discipline applied to a much more expensive object. (2) DESIGN, feeding SM576: 'may delete a backup' is scoped by INSTANCE, not by site, so a manage_domains grant reaches every domain's archives - which is worth deciding independently of who owns what, and is the sharpest case for the irreversible tier of SM576's lateral split. PLANNED with SM576."
---

# What is verified, and by what

| Claim | How established |
|---|---|
| A site's backup store can hold archives for other hosts | **Code**: `package_create($host)` writes into the local `_backups_dir()` for any configured domain |
| Archive names for other hosts appeared in edge's audit facet | **Observed** by the site agent; a facet records names, not current contents |
| Edge's store holds those archives now | **Unverified** - one `backup-list` call with `manage_domains` settles it |

# Why it matters twice

**For testing.** A cross-principal `backup-delete` probe on a site
declared expendable can destroy the only copy of a site that was never
part of the test. Any such test creates its own backup and deletes that.

**For the design.** SM576 asks whether the irreversible half of the
lateral grant should be its own capability. A backup is the strongest
case in that tier: no copy survives it, and unlike a brief or a safety
export its blast radius is not even confined to the site whose grant
authorised the deletion.

# Proving test

A unit test that `package_create` for a non-primary domain writes into
the instance's own backups directory (pinning the mechanism), and - once
SM576's tiers exist - that a grant holding the recoverable tier cannot
reach `backup-delete`.
