---
title: "SM115 - form submissions: view link, edit safety, audit"
subtitle: "See submissions from the connector; don't lose one to an open editor"
brand: plain
---

::: widebox
Several related points about form submissions: a quick way to view a form's
submissions from the connector/form UI; a concurrency concern (a submission arriving
while a submissions file is open in the editor could be lost on save); and recording
form submissions in the audit log (with a blank user, since the submitter is the
public).
:::

## View submissions from the connector / form

- From the form-connector area (and the form's row), a **"View submissions"** link
  that opens the submissions for that form. Today reaching them is indirect.

## Edit safety for submissions and other non-content files

- **Concern:** if a submissions file is opened in the editor and a new submission
  arrives, saving the editor could overwrite/lose the new one (last-write-wins on a
  file that is also being appended to server-side).
- **Direction:** open submissions (and other non-content files - configs, data) in
  **read-only** by default, with an explicit **Edit** button to opt into editing; and
  when editing, use the existing mtime/conflict guard so a changed-underneath file is
  refused rather than clobbered. Ideally submissions are append-only individual
  records, not a single editable blob, so concurrent arrivals never collide.
- Confirm what the lock/mtime guard currently does for these files and close any gap.

## Audit the submission itself

- A form submission is a material event - record it in the audit log (action
  `submit`/`form-submit`, origin e.g. `form`/`public`). The **user is blank** (the
  submitter is an anonymous public visitor); capture the form/target and IP instead.

## Status

Queued. Three threads: a UI link (small), the read-only-with-edit + conflict-guard
safety (the important one - data integrity), and a form-submission audit event. Pairs
with [[SM113]] (submission-change notifications) and [[SM078]] (audit targets).

## Status (reconciled)

**SHIPPED in v0.4.39.**
