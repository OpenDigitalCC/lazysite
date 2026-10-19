---
id: SM1195
title: "SM1195: check --fix says when a change did not take"
subtitle: "A fix is reported only when the path now carries the mode; a chmod the system quietly weakened is reported as not fixed, with the reason and the root command, and is tried once."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-19
raised-by: release manager, edge run of `lazysite check --fix` as ispadmin, 2026-10-19
area: tools
status-note: "SHIPPED (0.15.11) on n686: tools/lazysite-check.pl set_mode, set_owner, report_not_taken; t/unit/tools/86."
---

# What happened

On edge, `lazysite check --fix` run as ispadmin printed:

    fixed: chmod 2775 /home/ispadmin/web/edge.explore.lazysite.io/public_html (was 2751)
    fixed: chmod 2770 /home/ispadmin/web/edge.explore.lazysite.io/public_html/lazysite/git (was 2775)
    fixed: chmod 2770 .../lazysite/git (was 0770)
    fixed: chmod 2770 .../lazysite/git (was 0770)
    (--fix applied 4 change(s); this report reflects the post-fix state)
    [ FAIL ] lazysite/git is 0770 (group=www-data) - the CGI cannot write here; no setgid (new files miss the group)
    [ warn ] the docroot is 0775 - writable, but without setgid new files will not inherit the web-server group

Linux clears the setgid bit on chmod when the caller is not root and is not a
member of the file's group (ispadmin is not in www-data). chmod still returns
success. The tool believed the return value, said "fixed" for changes that had
not happened, and applied the same change again on each of its passes.

# What shipped

Every chmod and chown the fix path makes is followed by a stat, and compared
with what was meant to be set (`set_mode`, `set_owner`).

- A change that took is reported `fixed:` as before.
- A change that did not is reported `not fixed:` with the mode the path now
  has, the reason when it can tell (the setgid bit was dropped because the
  caller is not in the path's group; the change was refused with the system's
  error), and the command for someone who can: `sudo chmod 2775 '<path>'`.
- A change is tried once per run, keyed on path and mode, so the later passes
  no longer repeat it.
- The count line separates the two: `--fix applied N change(s), M not taken`.
- The same check covers the chown pass, the private store create and repair,
  the group-access walk under `lazysite/git`, and `git config
  core.sharedRepository` (read back after it is set).

The test simulates the quiet drop with a `CORE::GLOBAL::chmod` wrapper that
clears 02000 and returns true, since a test has no second user to be outside a
group with; `LAZYSITE_CHECK_GROUPS` stands in for the caller's group list.
