---
id: SM1238
title: "SM1238: the ACL dry run names what has not moved, and the Hestia updater runs it"
subtitle: "The 0.16.0 release notes tell the operator to run the SM296 dry run on every site and report each NOT MOVED line. The dry run printed no such line. It now names each rule whose files are still in the document root, and the updater runs it per site with --reapply-acls-dry-run (task #378)."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: "the release manager (task #378), after the 0.16.0 stable rollout"
area: installers
status-note: "SHIPPED (0.16.1) on n724: lazysite-acl.pl reapply's dry run prints NOT MOVED; lazysite-hestia-update-all.sh --reapply-acls-dry-run. t/tools/238."
---

# What happened

The 0.16.0 tag's ON UPGRADE step 2 tells the operator to run, as each site's own user,

    sudo -u <site user> perl <stage>/tools/lazysite-acl.pl reapply --docroot <docroot> --actor local

and adds: 'A line "NOT MOVED: <path>" names content whose access rule is stored but whose
files are still in the document root (the 0.10.8 SM296 state); report it. A site with no
such line is settled.'

Task #378 asks the updater to do that across the fleet. `--reapply-acls` only applies,
and `run_quiet` hides its output.

# What was found

The dry run never printed `NOT MOVED`. Without `--apply`, `reapply` listed every stored
rule ("Would re-apply N rule(s)") and stopped. `NOT MOVED` was printed only by the apply,
and only for a move that failed. So the step as written reported every site as settled,
whatever its state.

# What shipped

- The dry run names each rule that relocates content (a read list or draft, never the
  site-wide rule) whose path is still in the document root, alone or beside its store
  copy (SM981's both-trees case): `NOT MOVED: <path>`, then what it means. It moves
  nothing and exits 0, as before. `--json` carries `not_moved`.
- `lazysite-hestia-update-all.sh --reapply-acls-dry-run` runs that dry run on every
  in-scope site that upgraded (the same sites `--reapply-acls` sweeps), as the site's
  own user. Each `NOT MOVED` line becomes a finding labelled with the site. SM1235
  groups them, so a site with forty is one finding with examples. The run summarises
  how many sites have content not moved, how many are settled and how many could not
  run, and exits 2 (fleet has findings) if any site has one or its dry run failed.
- Given with `--reapply-acls`, it runs after the apply, so it reports what the apply left.
- UPGRADE.md names the flag.

# Not done

- The 0.16.0 tag's notes stay as they are. With this change they are true of 0.16.1.
