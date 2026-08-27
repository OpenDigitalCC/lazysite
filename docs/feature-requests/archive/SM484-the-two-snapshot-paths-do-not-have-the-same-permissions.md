---
title: "SM484: the two snapshot paths do not have the same permissions"
subtitle: "A safety snapshot refuses on a live site with exit 2, Permission denied. Carved out of SM381 so its shipped fixes could close and this could be owned"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in the pre-beta batch, all three remedies from the reproduction: (1) the RESTORE path's safety snapshot scopes to the archive's own blast radius - the common directory of its members, derived from the archive itself since nothing records a root - so a partner who can back up can roll back even with a hostile tree elsewhere on the host; an archive with no single common directory keeps the full snapshot, which for that target IS the blast radius. (2) package_create REPORTS what its staging copy could not read instead of shipping an incomplete artefact that says ok: unreadable DIRECTORIES are collected at the find level (where the silent omission actually happened - no copy() ever fired for a subtree find could not enter), file-level copy failures too; the result carries site-relative names, the manifest and log carry a COUNT only (the manifest travels). (3) _scrub_paths' lookbehinds gain the dot, so tar's ./-relative member names survive the scrub whole instead of mangling into the outside placeholder. t/integration/75 holds all three, from the rig's own cases. ORIGINAL NOTE: REPRODUCED 2026-08-24 at HEAD by rig (tmp/sm484-snapshots.pl), and sharper than filed. THE TWO PATHS NAMED: SitePackage::package_create (MCP site_backup) stages with unchecked copy() then tars the stage; Backups::action_backup_create (the safety snapshot inside site_apply AND backup_restore) tars the live tree directly. SAME FIXTURE, OPPOSITE FAILURES: an unreadable dir inside the scope makes package_create answer ok=1 with the blocked content SILENTLY MISSING from the artefact, while action_backup_create refuses ok=0 tar-exited-2. Neither answer is right - one refuses, the other hands over an incomplete artefact reported complete. THE UID QUESTION IS DISPROVED: both paths run in one worker process; the asymmetry is member-set and copy-vs-tar semantics, never identity. The literal permissions claim is also true (snapshot tar 0640 via O_EXCL claim, package tar 0664 via umask). LIVE GAP FOUND: SM412 scoped the apply-path snapshot (verified), but action_backup_restore's OWN safety snapshot is still unscoped (Backups.pm:622, no root) - on a multi-domain fixture, restoring a perfectly good scoped backup refuses 'safety snapshot failed', so a partner who can back up cannot roll back. ALSO: _scrub_paths mangles tar's ./-relative member names (./x becomes .<outside>), partly undoing SM386's name-the-path repair for exactly these messages. REMEDY LIST: scope the restore-path snapshot like the apply's; decide package_create's silent-omission policy (refuse or report, matching private_omitted's honesty); fix the ./-relative scrub. ORIGINAL NOTE: CARVED OUT OF SM381 ON 2026-08-23. SM381's fixes shipped in full - five refusal paths routed through output_page, 402/403 resolving the domain's content root, the checked write on the error-page writer, and the tar exit-1 fix (3 of 3 refusals before, 0 of 3 after, so a busy site genuinely could not be snapshotted). What did NOT close is the field failure those fixes were believed to explain. THE WITHDRAWAL IS THE POINT OF THIS FILING. The exit-1 story fitted every symptom, and both the pre-beta review and I believed it; retried on 0.10.15 the refusal names EXIT 2, PERMISSION DENIED, not exit 1. A fix that is real, that removes a real fault, and that turns out not to be the cause of the thing it was reached for is the most persuasive kind of wrong answer - it comes with evidence. It stayed as an open note on a shipped filing for four days, which is how a closed-looking item keeps a live question invisible. WHAT IS KNOWN: the two snapshot paths behave differently, and the difference is now demonstrated rather than inferred. WHAT IS NOT: which paths, whose uid, and whether it is specific to a content-root or multi-domain layout. First work is to name the two paths and diff what each runs as."
---

# What is known

A safety snapshot on a live site refuses with **exit 2, Permission denied**.
The two snapshot paths do not behave the same way, and that is demonstrated
rather than inferred.

# What was believed, and why it was wrong

SM381 found that the snapshot treated tar's *"some files differ"* warning
(exit 1) as fatal, which meant a busy site could not be snapshotted at all.
That is a real fault, it was fixed, and the fix holds -- three of three
refusals before, none after.

It was also believed to be the cause of the field failure, by the pre-beta
review and by me. **It is not.** Retried on 0.10.15 the refusal names exit 2,
not exit 1.

The exit-1 story fitted every symptom that had been collected, which is exactly
why it was convincing. A wrong answer that arrives with evidence and a working
fix attached is harder to catch than one that arrives with neither.

# Why this is its own filing

It sat as an open note on a filing marked shipped, whose other four parts were
genuinely done. Anyone reading the register saw a closed item; anyone reading
the note saw a live question. Splitting it costs one number and means the
question has an owner.

# First work

Name the two paths, and diff what each one runs as -- uid, cwd, and the target
it writes to. "Permission denied" names a subject and an object, and neither is
recorded yet.
