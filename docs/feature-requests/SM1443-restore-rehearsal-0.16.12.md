---
id: SM1443
title: "SM1443: the restore rehearsal rerun on the shipped 0.16.12 tarball"
subtitle: "The 0.16.11 rehearsal found that a full restore did not give a site that serves. SM1439 fixed it; this is the rerun on the shipped 0.16.12 tarball, with one restore command and lazysite check as the proof."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-11
raised-by: "release manager, rulings 241 and 242"
area: reliability
status-note: "DONE (PENDING) on n822, awaiting the release manager's confirmation. On the shipped 0.16.12 tarball one install.pl --restore-full onto a new docroot and cgi-bin took 743 ms; content, auth store, conf intact; check 0 failures. SM602 unchanged. Docs only."
---

# What was done

The rehearsal of the 2026-11-11 row (SM1438) was rerun from the shipped 0.16.12 tarball (sha256
`4b29a2b057320e64d91f81cc33381ca8a168128b8e05e2a2a4527ace679f2df0`, checked before unpacking),
in a scratch directory, from the unpacked tarball alone. A site was provisioned, canary content
and a sysops account were added, a full backup was taken with `action_backup_create('full')` and
copied out, and the docroot and cgi-bin were destroyed.

# The restore and the proof

One command onto a new docroot and cgi-bin, with nothing run after it:

```
install.pl --restore-full FILE --docroot NEW --cgibin NEWCGI --domain D --serving-group G
```

It returned 0 in 743 ms. The canary page, the auth store and `lazysite.conf` came back; the three
cgi-bin entry points are present; `.install-state.json` records 0.16.12. `lazysite check --group G`
on the restored docroot reported 55 ok, 2 warnings, 0 failures. A backup whose `lazysite/` is a
symlink is refused before anything is changed.

# What did not change

SM602 stands (after stable, ruling 240): the backup is still written inside the docroot it backs
up, so the rehearsal copied it out first.

# Record

`docs/RELIABILITY.md`, "Restore rehearsals": the 0.16.11 row's date is corrected from `11 Nov
2026` to the ISO `2026-11-11` that `tools/lazysite-compliance.pl` reads, and the rerun has its own
row. `docs/compliance/OBLIGATIONS.md` records the rerun and the row stays OPEN for the release
manager to confirm.
