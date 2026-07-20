---
title: "SM187 - Submissions viewer v2 (modal, row delete, agent read)"
subtitle: "Scrollable modal for the form-submissions table; delete a handled row; a least-privilege read_submissions capability so an agent can read submissions over API/MCP"
brand: plain
status: partial
status-note: "v2 built on claude/submissions-viewer-v2. Done: scrollable modal viewer; per-row delete (manage_forms, UI); new read_submissions capability + form-submissions on the token channel + a read_form_submissions MCP tool. FOLLOW-UP: bulk delete / export; a discover-forms helper for agents."
---

# SM187 - Submissions viewer v2

Field feedback on the SM182 submissions viewer.

## What was built

1. **Scrollable modal.** The table can get large, so it now opens in a fixed modal
   overlay with its own scrollable body (and an x-scroll wrapper for wide tables)
   instead of expanding inline. A form selector in the modal header switches
   between stores when a handler holds more than one. Every cell/header still
   goes through `esc()` (values are attacker-supplied).

2. **Delete a handled row.** Each row has a Delete button. `action_form_submissions`
   returns a stable `_id` per row (a hash of its raw JSONL line); the new
   `form-submission-delete` action (manage_forms, POST/CSRF, audited) rewrites the
   store atomically (temp + rename) without the matched line. It is **UI-only**
   (not on the token channel) - deleting PII is more sensitive than reading. Path
   is confined to a `.jsonl` under the docroot; a bad/unknown id is a clean
   refusal, not a silent success.

3. **Agent read, least-privilege.** A new capability **`read_submissions`** lets
   an agent read submissions without `manage_forms` (which would also let it edit
   forms). `form-submissions` is now gated `manage_forms OR read_submissions` on
   BOTH the cookie and token channels (parity preserved), and a new MCP tool
   **`read_form_submissions`** (gated `read_submissions`) returns the table.
   Reading is thus available to an operator (manage_forms) and to a purpose-built
   agent (read_submissions); deleting stays operator-only.

## Permissions summary

- Read submissions (UI): `manage_forms`.
- Read submissions (API/MCP agent): `read_submissions` (or `manage_forms`).
- Delete a submission: `manage_forms`, UI only.

`read_submissions` joins `@CAP_KEYS`, both capability grids (Groups + Users), and
the capability describe (unlocks `form-submissions` over the API and
`read_form_submissions` over MCP); the grid-parity and capability guards enforce
consistency.

## Tests

`t/unit/lib/07-plugins-handlers.t`: each row has a stable 16-hex `_id`; delete
removes the identified row (the other survives); malformed/unknown id and a
traversal path are refused. The cap-gate parity, grid-parity, audit and
write-path guards classify the new action and capability.

## Follow-up

Bulk delete / CSV export of a store; an agent-facing "which forms have
submissions" discovery helper (today `read_form_submissions` takes a known form
name and reads the default store path).
