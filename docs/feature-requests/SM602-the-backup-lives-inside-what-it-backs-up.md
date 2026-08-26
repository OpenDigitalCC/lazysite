---
title: "SM602: the full-system backup is written inside the docroot it backs up"
subtitle: "The declared RPO is bounded by a scheduled backup, and that backup shares the fate of the thing it protects. Nothing in the reliability declaration says to move it off the box."
brand: plain
standard-margins: true
status: candidate
status-note: "DOCUMENTED for 0.11.0, which was the recommendation: RELIABILITY.md now carries a table of which failure classes each RPO covers, says plainly that the 24-hour bound does NOT hold for docroot loss, and states that an operator needing it to hold must copy backups off the host because no shipped mechanism does. The default stays - the backup beside the site needs no credentials and nothing to configure. A shipped off-box target remains a feature for after stable. FOUND 2026-08-26 by running the 0.11.0 stable-cycle restore rehearsal rather than by reading about it. The rehearsal destroys the docroot and restores onto a new one - and it could only do that because the SCRIPT copies the backup out first. A real operator has no such step. `action_backup_create('full')` writes to `lazysite/backups/`, which is inside the document root, so the disaster the rehearsal simulates - the docroot is gone - takes the backup with it. WHAT THIS MEANS FOR THE DECLARATION: RELIABILITY.md bounds 'RPO - site content' and 'RPO - auth and configuration' at 24 hours, each 'bounded by a scheduled backup'. That bound holds for the failure classes where the docroot survives - a bad edit, a broken upgrade, a deleted page - and does NOT hold for docroot loss: disk failure, an errant rm -rf, or a compromise that reaches the tree. For that class the RPO is unbounded, because there is nothing left to restore from. NOT A CODE DEFECT, and deliberately filed as a documentation and default gap rather than a bug: storing the backup beside the site is the right DEFAULT (it is the only location the engine can write to unaided, it needs no credentials, and it makes `--restore` work with no configuration). What is missing is that nothing tells the operator the backup must ALSO live somewhere else for the RPO to mean what it says, and no shipped mechanism helps them do it. THE HONEST FIX IS DOCUMENTATION FIRST: RELIABILITY.md should say which failure classes each RPO covers, and OPERATOR.md should say to copy backups off the host. A shipped off-box target (rsync/S3/WebDAV) is a feature and waits until after stable. RAISED DURING A STABLE PREP, so worth stating plainly: this does not block the promotion - the mechanism works and the rehearsal passed in 69 ms - but the declaration currently claims more than the default arrangement delivers."
---

# What the rehearsal had to do

```sh
# the backup lives INSIDE the docroot about to be destroyed
cp "$A/lazysite/backups/$BK" "$WORK/backups-kept/"
rm -rf "$A"
```

Without that copy there is nothing to restore from. The rehearsal would
have proved only that a restore works when the backup survives - which is
not the question a disaster rehearsal asks.

# Which failure classes the declared RPO actually covers

| Failure | Docroot survives? | Backup survives? | RPO holds? |
|---|---|---|---|
| Bad edit, deleted page | yes | yes | yes |
| Broken upgrade | yes | yes | yes |
| Disk loss, `rm -rf`, compromise | **no** | **no** | **no** |

The mechanism is sound and fast. The claim is what needs qualifying.
