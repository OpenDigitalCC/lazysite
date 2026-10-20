---
id: SM1205
title: "SM1205: the Hestia deploy reports the final check's verdict, not install.pl's interim one"
subtitle: "On every 0.15.10 to 0.15.13 edge deploy the batch updater listed install.pl's interim health-check exit 4 as a finding on a site whose final check passed. The interim result is a progress line now; a failure that survives the repair is still reported."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: "the release manager, reading the 0.15.13 edge rollout's findings list"
area: installers
status-note: "SHIPPED (0.15.14) on n694: the deploy's interim exit-4 line is one progress line with no level marker, so the updater's findings filter no longer keeps it; exit 5 still names a failure the repair left. t/tools/189."
---

# What happened

`installers/hestia/lazysite-hestia-deploy.sh` runs `install.pl`, whose own health
check runs before the deploy's permission pass and `lazysite check --fix`. On exit 4
the deploy printed two lines, the first beginning `WARN:`, and carried on; the final
check decides. The batch updater (`lazysite-hestia-update-all.sh`) keeps lines that
match its `NOISE_RE`, and `^WARN` does; the second line does not. So every site whose
final check passed reported `[1] WARN: install.pl installed the release and its
health check named a failure (exit 4);` - the first line only, ending in a semicolon.
The release manager asked for a `--verbose` run to find a failure that was not there.

# What shipped

- The interim result is one progress line, `==> install.pl's own health check named a
  failure before the permission pass and the repair (exit 4); the final check below
  decides`, with no level marker, so it is not a finding. When the final check passes
  the deploy says the failure was cleared by the repair.
- When the final check still fails the deploy exits 5 as before, prints `NOT
  SERVICEABLE`, and the updater prints the whole captured output of that site.
- The message is one line, so nothing is cut to its first line.

# Not done

- The updater's filter still keeps a line by its first words; a future two-line
  warning would be cut the same way. No other such message was found.
