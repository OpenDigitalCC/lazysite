---
title: "lazysite 0.17.0 - test plan"
subtitle: "What changed for a site since 0.16.12, and how to walk it on edge"
brand: plain
standard-margins: true
---

# Scope

0.17.0 is the stable promotion of 0.16.12 with the fixes of the last two field passes. Walk it on
edge and its subdomains only. Report each row as PASS, FAIL (with what you saw) or NOT RUN (with
why). Results go to the lazysite dev inbox.

# Before you start

- `lazysite --version` reports 0.17.0 on the instance.
- Note the time; the audit-trail rows below are checked from it.

# T1 - an unfinished backup is never a backup (SM1446)

The deploy found an unfinished backup on edge: a 0-byte `lazysite-full-…T065507Z.tar.gz` and a
staging directory `lazysite/backups/.stage-…` from 12 Nov. Use them before you remove them.

```datatable
columns: Ref | Step | Expected
widths: 1.2cm | X | X
---
T1.1 | Open the Backups page. | The 0-byte file is listed apart, under unfinished, with its time and a Delete; it is not in the backup list.
T1.2 | Run `lazysite check` on edge. | It names the unfinished backup and the staging directory left by a stopped backup.
T1.3 | Try to restore the unfinished file (page or CLI). | Refused, naming the file. Nothing is changed.
T1.4 | Delete it from the page; remove the staging directory as the check advises. | Both gone; the check no longer names them.
T1.5 | Start a full backup from the page. | The page answers at once with the name and in progress, and follows it until it is a backup.
T1.6 | While T1.5 runs, start a second full backup; try to delete or restore the running one. | Each refused while it runs.
T1.7 | When T1.5 ends, read the audit trail. | A start row and an outcome row, both naming the file; the outcome names the kind full.
T1.8 | The finished backup's row on the page. | Size and sha256 shown; restore offered.
```

# T2 - a refusal names the user who can run the command (SM1447)

```datatable
columns: Ref | Step | Expected
widths: 1.2cm | X | X
---
T2.1 | As root, run `lazysite acl` on a site. | Refused, naming the owner of the files it reads (the web server's user on Hestia), not the directory's owner.
T2.2 | Run the command as the user named. | It runs.
T2.3 | Make one directory of a test subdomain unreadable to the site user (chmod 700, another owner), then run `lazysite check` as the site user. | No ok for the walks that could not read it; each warning names the directory's owner. Restore the mode afterwards.
T2.4 | Read every piece of advice in the T2.3 output. | Each command is spelled as the instance spells it (the full path or wrapper), never a bare `lazysite`.
```

# T3 - the bad-URL blocker counts credential-file probes (SM1444)

```datatable
columns: Ref | Step | Expected
widths: 1.2cm | X | X
---
T3.1 | From one test address, request `/.docker/config.json`, `/.kube/config`, `/appsettings.json` and `/aws-exports.js` until the threshold. | The address is blocked as for any other bad-URL pattern.
T3.2 | Place a real file `/app.js` on a test subdomain and request it. | Served; not counted.
T3.3 | Read the stats for T3.1's hits. | Counted as noise, not as visitor pages.
T3.4 | Unblock the test address. | Unblocked.
```

# T4 - the deploy's own findings

These came from the 0.17.0 rollout and are for the operator, not the engine. Note only whether
each is still so on edge:

- `trusted_proxies` is the private-range default: send `X-Forwarded-For: 192.0.2.55`; the
  request must not be seen as 192.0.2.55.
- A shared `manager` account exists (pre-SM659).
- Content roots under `sites/` not declared (`sites/jpm-stock`, `sites/studio`).
