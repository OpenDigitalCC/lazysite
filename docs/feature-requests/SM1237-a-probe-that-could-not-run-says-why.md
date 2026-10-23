---
id: SM1237
title: "SM1237: a probe that could not run says why"
subtitle: "The 0.16.0 rollout ended \"probe: 16 clean, 0 exposed, 16 could not run\" with no reason for any of the sixteen. The probe gives a reason for every site it could not confirm, the rollout reports the reasons grouped as findings, and a root --fix creates the private store that a Hestia site without one cannot create, which made the probe skip."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: "the release manager, reading the 0.16.0 stable rollout report (32 sites)"
area: installers
status-note: "SHIPPED (0.16.1) on n724: _probe_unconfirmed_reason in the CLI, probe_site in the updater, the half-applied cause in _probe_protect, the store created by a root --fix. t/tools/237."
---

# What happened

The 0.16.0 rollout's summary said `probe: 16 clean, 0 exposed, 16 could not run`.
Nothing in the report said why for any of the sixteen.

# What makes a probe "could not run"

`lazysite probe` runs `lazysite-check --check-acl https://<site>/` as the site's
owner. It passes only on the probe's own confirmation line and is exposed only on
its own exposure line. Everything else is NOT CONFIRMED, and the CLI exits 3:

- `ACL PROBE SKIPPED: <cause>`. The cause is one of: not an http(s) URL; acls.json
  unreadable or undecodable; no probe directory in the docroot; running as root;
  the engine modules would not load; the engine refused to protect the probe folder;
  the rule was stored and nothing moved.
- The probe reached the fetch and got no usable answer, or could vouch for only
  some file types.
- The check printed no verdict at all, for example when it did not start.

The updater counted exit 0 as clean, exit 3 as could-not-run and any other status
as EXPOSED. It read nothing else.

# The defects

- **The reason did not reach the report.** For the skip marker, the CLI printed the
  cause. For the other two cases it printed a guess: "usually a docroot or ACL store
  the probe could not write: run `lazysite repair`". The updater read only the exit
  status. In the quiet report it dumped a probe that exited 3 whole, as FAILED, one
  transcript per site.
- **A probe command that did not finish was counted as exposed.** The CLI's `fail()`
  exits 1, so a refusal such as "no registered site named X" landed in the exposed
  column.
- **The half-applied reason pointed at text nobody printed.** "The engine refused to
  protect the probe folder: the rule ... IS IN FORCE ... See the warnings for the
  diagnostic". The probe never printed the warnings.
- **The probe fails needlessly on a Hestia site that never protected anything.** The
  private store is `<docroot>-lazysite-private`. Its parent is the Hestia domain
  folder, mode 0551 (lazysite-app.sh says so), so neither the site user nor the CGI
  can create it. The check's store section stays silent for a site that gates
  nothing, so no `--fix` created the store. The probe, which protects a throwaway
  folder as the site user, then answers SKIPPED on every such site. This was
  reproduced on a fixture with its domain folder at 0551. Whether it explains the
  field's sixteen is not known: the reasons now in the report will say.

# What shipped

- `lazysite probe` prints `<site>: NOT CONFIRMED: <reason>` for every site. The
  reason is the skip cause, else the probe's own no-answer or could-not-vouch
  verdict, else "the check gave no probe verdict (exit N): <last line>". The summary
  lists each reason with its sites. The guess is gone.
- The updater's `probe_site` reads the verdict from the probe's words. For each site
  that could not run, it records `probe could not run: <reason>` as a finding, so the
  SM889/SM1235 grouping reports one line per reason with its sites. The summary line
  points at the findings. A probe that exited 3 is filtered like a pass (its reason is
  the finding). A probe command that did not finish is could-not-run with its last
  line as the reason: its output is printed whole, and it still marks the fleet for
  a human (exit 2), as the exposed count did.
- The probe's half-applied reason carries the warning's cause, for example "the probe
  folder could not be moved into the private store: cannot create the private store
  at ...: No such file or directory".
- A root `--fix` now creates the private store on a site that protects nothing when
  the engine cannot create it itself. It is created empty, in SM313's shape (the site
  user, the CGI group, 2770). Nothing is reported, and a non-root run is unchanged.
  The deploy and `repair` run `--fix` as root, so the next rollout creates the store
  before it probes. This is a separate commit, so it can be held on its own.

# Not done

- Running the probe as the CGI user rather than the site user. That is a different
  decision about who protects content.
