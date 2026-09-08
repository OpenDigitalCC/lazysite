---
id: SM774
title: "SM774: a start page on a site must resolve"
subtitle: "131E-05 step 6 on 0.13.6: a start page pointing at a content page that was later deleted sent every sign-in to a 404. A manager-page target is checked against the account's grants when set and at every sign-in; a domain target was checked for syntax and confinement only - never for the page. The warning and the fallback for exactly this case existed and never fired."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-08 on claude/sm774-a-start-page-on-a-site-must-resolve. validate_start_page checks that a domain target's path names a page on that domain - x.md, x/index.md, a legacy x.html or a file as spelled, through the private store first - so it is refused by name when set ('no page at '/x' on this site - it may have been deleted or moved') and, because resolve_start_page validates again at every sign-in, a page deleted afterwards lands on the fallback flagged with that reason, which the account sheet's existing warning shows. t/unit/manager/157: a never-existing page is refused on the primary and on an alias by name; root, folder and legacy spellings count; a page set, then deleted, lands on the flagged fallback."
---

# What the field saw

Set a user's start page to a page, sign in: lands there. Delete the page,
sign in: lands on the same URL, now a 404. The API still reported
`current` set, no `unreachable`, and the account sheet showed no warning -
though the sheet carries one for exactly this case, and the API a
`fallback`. Setting a start page to a path that never existed was accepted.

# What was true

`validate_start_page` checked a manager target against the account's
capabilities (SM724 rule 2) and a domain target against the path grammar
and the account's domain confinement - not against the site. Since
`resolve_start_page` re-validates at every sign-in, the manager half fell
back with a reason when a grant changed, and the domain half could not,
because nothing it checked ever changes when a page is deleted.

# What is built

- `_page_resolves`: the path names a page on that domain today, in the
  spellings the front end serves (`/x` → `x.md`, `x/index.md`, legacy
  `x.html`, or a file as spelled; `/` and `/x/` → the index), looked up
  through the private store first so a gated page counts.
- `validate_start_page` runs it for a domain target, after the domain
  check. Set time: refused by name - `no page at '/zz' on this site - it
  may have been deleted or moved` (an alias names its host). Sign-in: the
  fallback, `start=unreachable`, with that reason; the sheet's warning
  shows it and the setting stays for the user to change.
- `t/unit/manager/157`: the fixture now carries the pages it points at;
  a never-existing page is refused on the primary and on an alias by name;
  root, folder and legacy spellings are accepted; a page set, deleted, and
  signed into lands on the flagged fallback with the reason.

# Also from the run, not built

A plain manager user navigating to `/manager/` directly lands on
`/manager/config`, which is a heading and nothing else for an account
without `manage_config`, and its nav offers Users, Groups, Backups and
Plugin Manager without the lock markers a sysop's nav shows. Filed as
SM775, a candidate: the manager index should land where the sign-in
fallback lands, and the nav should mark what the account cannot reach.
