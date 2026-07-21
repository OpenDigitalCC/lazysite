---
title: "SM182 - In-manager form-submissions viewer (safe escaped table)"
subtitle: "Read form submissions from the reserved lazysite/ store without the raw file editor"
brand: plain
status: shipped
status-note: "SHIPPED 0.9.5 (2026-07-19): in-manager form-submissions viewer (the form-submissions control-API action + an escaped table in plugin-config). Extended by SM187 (submissions viewer v2) in 0.9.8."
---

# SM182 - In-manager submissions viewer

## Why

Form submissions are written by the local-storage handler to
`lazysite/forms/submissions/<form>.jsonl` (one JSON record per line). That path
sits in the reserved `lazysite/` tree, which the 0.7.x security work put behind
the file-editor's reserved-file guard: an operator can *see* the folder but
opening a `.jsonl` file returns *"This file is part of the lazysite control area
and cannot be edited here."* The result is that submitted data - the whole point
of a contact form - became unreachable from the manager UI.

The plugin-config page already advertised a **View submissions** affordance, but
it deep-linked to `/manager/files#<path>`, which dead-ends at that same guard.

## What

Make **View submissions** open an inline, escaped table on the plugin-config
page - no raw-file access, no new surface.

## Design

**Backend** (`action_form_submissions($file)`, `manage_forms`, GET/read):

- Path-confined to the docroot, `.jsonl` only, no `..` traversal - the same
  confinement discipline as the rest of the manager file actions.
- Parses each line as JSON; collects the **union** of record keys as columns;
  returns the most-recent `CAP` (500) rows so a busy form can't blow up the
  response; every value is stringified (nested values JSON-encoded) and returned
  **verbatim**.
- Reports `total`, `shown`, `truncated`, and `malformed` (unparseable lines are
  counted and skipped, not fatal). A missing file is an empty table, not an
  error (a form with no submissions yet).

Gated on both channels at parity: `'form-submissions' => 'manage_forms'` in
`%COOKIE_CAP`, and enrolled in the `t/lint/14` COOKIE_READ allowlist as a
genuine read (no state change).

**UI** (`starter/manager/plugin-config.md`): **View submissions** toggles an
inline panel that lists the store's `.jsonl` forms and renders the selected
one as a `<table>`. The server returns values verbatim precisely so the client
owns escaping - **every** cell, header and label passes through `esc()` (which
neutralises `& < > "`), so a hostile submission (`<script>...`) is displayed as
inert text. A row-count note surfaces truncation and malformed-line counts.

## Why it is safe

The injection risk is real - submitted values are attacker-controlled - so the
boundary is explicit: parse + cap server-side (testable, bounded), escape
client-side at render. The backend never emits HTML; the client never trusts a
value. `t/unit/lib/07-plugins-handlers.t` asserts a `<script>` value survives
verbatim through the backend (so the escaping responsibility is unambiguous),
that traversal / non-`.jsonl` paths are refused, that malformed lines are
counted not fatal, and that the row cap holds.

## Acceptance

- **View submissions** on a file handler opens a table of that form's
  submissions inside plugin-config, with no reserved-file guard in the way.
- A submission containing HTML/script is shown as inert text.
- A form with hundreds of submissions renders the most-recent 500 with a
  truncation note; malformed lines are reported, not fatal.
- A non-`.jsonl` or traversal path is refused by the backend.
