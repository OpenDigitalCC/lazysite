---
title: "SM187 - Submissions viewer v2 (modal, row delete, agent read)"
subtitle: "Scrollable modal for the form-submissions table; delete a handled row; a least-privilege read_submissions capability so an agent can read submissions over API/MCP"
brand: plain
status: shipped
status-note: "v2 built on claude/submissions-viewer-v2. Done: scrollable modal viewer; per-row delete (manage_forms, UI); new read_submissions capability + form-submissions on the token channel + a read_form_submissions MCP tool. FOLLOW-UP SHIPPED in 0.10.1 edge (branch claude/sm187-submissions-viewer): bulk delete (row checkboxes + select-all + Delete-selected -> new form-submissions-delete-bulk action, manage_forms, %MUTATING, audited, one atomic rewrite, UI-only) and client-side CSV export (Download CSV, built from the loaded rows, RFC-4180 quoted, no new server surface). The discover-forms helper is delivered by SM214's form_list (name/handlers/has_store/rows), so it is not duplicated here. Remaining: nothing outstanding - status corrected from partial to shipped 2026-08-09, having verified each claimed deliverable against the code rather than the note: form-submissions-delete-bulk in lazysite-manager-api.pl, read_submissions in Capabilities.pm, read_form_submissions in lazysite-mcp.pl, and the Download CSV / Delete selected controls in the manager pages."
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

## Follow-up (shipped in 0.10.1 edge)

- **Bulk delete.** The viewer gains a checkbox per row + a select-all header box
  and a "Delete selected" button. A new `form-submissions-delete-bulk` action
  (`manage_forms`, `%MUTATING`, audited, UI-only) takes a list of row ids and
  drops all matched rows in ONE atomic rewrite (temp + rename), same path
  confinement and stable-id matching as the single delete. Unknown ids are not
  matched; the result reports how many were removed; an empty list, a malformed
  id, a traversal path, or a batch matching nothing are all clean refusals.
- **CSV export.** A "Download CSV" button builds the file client-side from the
  rows already loaded (visible columns + `quarantined`/`spam_reason`, every cell
  RFC-4180 quoted) - no new server surface, so no extra PII endpoint.
- **Discover-forms.** Delivered by SM214's `form_list` (enumerates forms with
  their handlers, `has_store` and submission `rows` count over API + MCP), so it
  is not duplicated here.
