---
title: "SM124 - connector onboarding: align grant, brief, and docs"
subtitle: "The brief should match the issued grant and whoami"
brand: plain
---

## From the field report (Medium/Low)

Grant vs task
: "The onboarding brief was for a themes task, but the issued token granted only
  manage_content / nav / forms - not manage_themes / manage_layouts. The machine-readable
  block did not match the work." Make the brief's machine block equal `whoami`, and align
  the issued grant with the task (a themes brief implies manage_themes / manage_layouts).

Admin group vs token caps
: "Being in lazysite-admins did not confer theme/layout capability on the partner token -
  two independent access planes." Document this explicitly (the manager UI now shows the
  toggles for operator accounts - SM094 fix - but the *docs* should state that
  partner-token capabilities are independent of admin-group membership).

Idempotent MKCOL (Low)
: "MKCOL on an existing internal collection returned 403 (looks like a permission
  failure) rather than 405/200; the child creates still succeeded, but the signal is
  misleading." Return 405 (or 200) for MKCOL on an existing collection.

## Status

Queued. Docs + small fixes: brief machine-block = whoami; grant-matches-task guidance;
a docs note on the two access planes; WebDAV MKCOL idempotency status code.

## Status (reconciled)

**SHIPPED in v0.4.40.**
