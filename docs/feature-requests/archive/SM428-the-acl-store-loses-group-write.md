---
title: "SM428: the ACL store locked the manager out, once per deploy"
subtitle: "save_acls wrote 0640 while lazysite-check requires the file to be group-writable. Every `acl reapply` dropped it, every health pass repaired it - so the only trace was a repair that ran every single time."
brand: plain
standard-margins: true
status: shipped
status-note: "FOUND 2026-08-20 in the operator's own 0.10.18 deploy log, and visible in the 0.10.17 one before it - the same line, the same file, both times. THE DEFECT: the ACL store is written by TWO identities on a group-shared docroot (the site user via CLI verbs and `acl reapply`; the www-data CGI via the manager's permissions UI), and save_acls set 0640 - readable but not writable by whichever identity did not write it last. lazysite-check names the consequence exactly: 'acls.json ... is not writable by the CGI (www-data) - the manager cannot save it'. THE REASON IT SURVIVED is the shape worth remembering: the deploy's `acl reapply` step dropped the mode, and the health pass that runs afterwards repaired it, so the log showed a successful repair rather than a failure. A repair that runs EVERY time is not a repair - it is a writer disagreeing with its own checker on a schedule, with a window in between where an operator's permission change silently fails to save. Nobody reads a fixed line as a bug. FIX: 0660, matching the sibling auth files the same check requires group-write on (users, groups) and the 2770 setgid directory they live in; no world bits either way. The test asserts group-write and no-world rather than a literal mode, and pins that the checker still lists the file - the two drifting apart IS the defect."
---

# What the log showed, twice

```
[ FAIL ] lazysite/auth/acls.json (0640, ispadmin:www-data) is not writable
         by the CGI (www-data) - the manager cannot save it
  -> repairing
fixed: chmod 0660 .../lazysite/auth/acls.json
```

::: widebox
The repair worked, so the deploy ended green and the line read as
housekeeping. It is not housekeeping: between `acl reapply` and the health
pass, the manager could not save a permission change - and an operator who
runs an ACL verb *without* a following health run stays in that state.
:::

# Why 0660

The store's directory is 2770 - setgid, group-writable - and its siblings
`users` and `groups` sit in the same group-writable list in
`lazysite-check.pl` for the same reason: the manager saves them through the
www-data CGI. `acls.json` was the odd one out.
