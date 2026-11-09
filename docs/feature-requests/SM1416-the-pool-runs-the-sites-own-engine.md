---
id: SM1416
title: "SM1416: the pool runs the site's own engine"
subtitle: "The FastCGI pool rendered with the package's processor while the manager, auth and DAV CGIs ran the site's own copy, so after a package upgrade one site ran two engine versions. The pool now runs the site's own processor and lib; a site whose engine is missing gets 503 and a check FAIL."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-09
raised-by: "n788's finding; release manager, ruling 203; numbered by ruling 211"
area: runtime
status-note: "SHIPPED (PENDING, 0.16.9) on n791 with rulings 203, 206 and 211: the launcher execs the site's processor from CGIBIN= or the docroot's sibling cgi-bin; a missing or unreadable site engine gets 503, a log line and a lazysite check FAIL; the shared-engine marker keeps the image's engine. t/integration/458."
---

# What was asked

On Hestia and deb sites that run the FastCGI pool, `tools/lazysite-pool.pl` exec'd the
processor beside itself, the package's. The manager, auth and DAV CGIs ran the site's
own copy. After a package upgrade the site had not yet taken, the pool rendered with the
new engine and every other surface with the old one (n788).

Ruling 203: the pool loads each site's own processor and lib, so a site runs one engine
version and upgrades through its own `upgrade`. A skewed package engine is never used for
a site.

# What shipped

- The launcher execs the site's own `lazysite-processor.pl`, from the cgi-bin the pool
  already relays to: `CGIBIN=` in the pool conf, else the docroot's sibling `cgi-bin`.
  That processor loads its parts beside itself and the lib beside the docroot.
- If the site's processor, its parts or its lib is missing or unreadable to the pool's
  account, the pool answers every request 503 and logs the missing paths and the remedy
  at start. It never falls back to the package's engine (ruling 206).
- `lazysite check` reports `pool engine: the site's own (...)`, or a FAIL naming what
  is missing and the remedy: `lazysite reinstall` (or `upgrade`), then
  `systemctl restart lazysite@<site>`.
- An engine whose root carries the shared-engine marker (`SHARED-ENGINE`, SM1361) keeps
  running its own processor, as the container did before. The marker is read from the
  launcher's own tree, never the site's.

Ruling 211 keeps the choices as built: the pool takes `CGIBIN=` from its conf, else the
cgi-bin beside the docroot, so a site whose engine is elsewhere without `CGIBIN=` gets 503
and a check FAIL; a repaired site returns on the pool's restart.

# Tests

t/integration/458 runs the launcher from a package tree whose stand-in engine leaves a
mark, against a site laid as install.pl lays one. With the site's tree in place the page
renders with the site's engine and the mark is never made. With the site's processor gone
the request gets 503, the mark is never made, the log names the file and the check names
the fault. It fails with either change reverted.
