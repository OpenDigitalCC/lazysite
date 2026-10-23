---
id: SM1235
title: "SM1235: a finding that differs only by a path is one finding"
subtitle: "The 0.16.0 rollout gave one site about seventy finding lines, one per file it had displaced. The quiet report now collapses a message that differs only by a path into one finding with the count, where the files went, three examples and a file with the full list."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: "the release manager, reading the 0.16.0 stable rollout report (32 sites)"
area: installers
status-note: "SHIPPED (0.16.1) on n724: group_findings normalises paths before grouping. t/tools/235."
---

# What happened

On the 0.16.0 rollout the findings for sumaya.fund held about seventy lines of

    WARNING: both trees held 'docs/X.md': the private store's copy is kept ...
    the document root's copy was moved to <dir>/docs/X.md, where it can be recovered

one per file that `acl reapply` had found in both trees. The operator could no longer
copy the report.

# The cause

`group_findings` groups one line per distinct message (SM889). Each path makes a
message distinct, so a per-file note groups to one line per file.

# What shipped

- Before grouping, each message is normalised: an absolute path, and a quoted name
  with a slash or an extension, become `<path>`. A leading log timestamp is dropped.
- A group that holds more than one distinct message prints once: the normalised
  message, the instance count, the directory each path slot is under per site (for
  the both-trees line, the displaced directory), three examples, the file holding
  every original line, and the sites.
- The full list is written to `lazysite-rollout-findings-<time>-<pid>.txt` in
  `LAZYSITE_FINDINGS_DIR` (default `$TMPDIR`, else `/tmp`), only when a group
  needs it. `--verbose` still prints every line as it happens.
- This covers every per-path finding, not only the both-trees one: a check finding
  naming each site's own docroot, `NOT MOVED: '<path>'`, a log line that differs
  only by its timestamp.
- A message with no path, or one copy of it, prints exactly as before.

# Not done

- A URL is not treated as a path, so the same warning about two sites' URLs is
  still two findings.
