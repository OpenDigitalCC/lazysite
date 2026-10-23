---
id: SM1220
title: "SM1220: the Hestia deploy's checks read the protected store"
subtitle: "On edge every deploy's findings carried four warnings that the checks could not read the private store as ispadmin. They came from install.pl's own check, run as the site user. The deploy now leaves that check to its root pass."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: "the release manager, reading the edge deploy findings (#356)"
area: installers
status-note: "SHIPPED (0.16.1) on n707: the deploy passes install.pl --health-check-by-caller; the final check already ran as root. No group change. t/tools/195."
---

# What happened

Every Hestia deploy's findings listed four warnings (address rules, db: template,
form-pattern, protected content): "could not read directory
.../public_html-lazysite-private/sites (Permission denied)" as ispadmin. The private
store belongs to the web server group and ispadmin is not in www-data.

The ruling (#356): the deploy runs the read-only checks as root; no group change, because
several lazysite users share the host and www-data membership would give one of them group
write to every site.

# The cause

The deploy's final `lazysite-check.pl ... --fix` already runs as root: the script requires
root and has no `sudo -u` on it. The warnings came from the other check: `install.pl`, run
as the site user, ends with its own health check, and as that user it cannot open the
store. The batch updater's filter keeps any line containing "Permission denied".

# What shipped

- `install.pl --health-check-by-caller` skips its closing check and prints
  `Health check: not run here`, so "not run" does not read as "healthy".
- The deploy passes it. The one check is the final one, as root, after the permission
  pass; it covers the private store and is the deploy's verdict (SM1205).
- Nothing new runs as root and nothing runs as the site user that did not before.

# Not done

- The final check's `--fix` runs as root today, as before this change; running only the
  repair as the site user is a separate decision.
