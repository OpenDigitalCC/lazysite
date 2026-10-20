---
id: SM1228
title: "SM1228: the practice copies take the extension-* action names"
subtitle: "The served field-practice briefing and its source taught the plugin-* action spellings; both name extension-* now, and t/lint/266 no longer exempts the briefing."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: inbox/2026-10-18-app-practice-action-names-updated.md (the lazysite-sites agent); SM1125 "Open"
area: docs
status-note: "SHIPPED (PENDING) on n712: docs/practice/app-practice.md and starter/docs/ai-briefing-practice.md (re-imported) name extension-*; t/lint/266 scans the briefing. plugin-* still served, audited deprecated (t/unit/manager/167)."
---

# What happened

SM1125 left one item open: the briefing a script author is given taught
`plugin-list`, `plugin-action`, `plugin-read` and `plugin-save`, and t/lint/266
exempted it (recognised by its import checksum) until its source changed. The
sites agent's reply of 2026-10-18 said its own source (`APP-PRACTICE.md`) names
the new spellings and that the repository copy, `docs/practice/app-practice.md`,
"is yours and still carries the old names".

# What shipped

- The seven occurrences in `docs/practice/app-practice.md` (the repository copy
  is the custodian copy since SM733; the site agent's file differs in far more
  than these names and was only read) now say `extension-list`,
  `extension-enable`, `extension-action`, `extension-read` and `extension-save`.
- `tools/import-field-practice.pl` was re-run, so `starter/docs/ai-briefing-practice.md`
  carries them, with a new body checksum and the engine version stamp.
- t/lint/266 loses its exemption for a file that carries an import checksum: the
  generated briefing is scanned like every other shipped file.
- `lazysite-manager-api.pl` (line 455) rewrites `extension-*` to `plugin-*`
  before dispatch, and a sent `plugin-*` still works, flagged as the deprecated
  spelling in the audit; t/unit/manager/167 and 168 hold both names.

The sites agent asked whether `plugin-enable` has a current name: it is
`extension-enable` (and `plugin-disable` is `extension-disable`). The answer is
filed in the sites inbox.
