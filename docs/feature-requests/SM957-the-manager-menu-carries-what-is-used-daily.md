---
id: SM957
title: "SM957: The manager menu carries what an operator uses daily; the rest is a click further"
subtitle: "A review of the 17 menu entries: Submissions has no entry, while Handlers, used at setup, sits in the menu."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-07
raised-by: release manager, 2026-10-07
area: manager
status-note: "SHIPPED (0.15.3): menu Site/Setup/Access/System; /manager/submissions (the viewer moved, ?submissions= redirects) with the bell's unread submission count; one Extensions entry; Handlers off the menu, linked from each form and Extensions. Also: the bell's marks were refused GETs, now POST. t/unit/manager/202-204."
---

# The request (release manager, 2026-10-07)

> on the submissions, currently submissions are found by navigating to extension
> config. they should be easier to find, maybe on the menu. handlers doesnt need
> to be on the menu as it isn't every day used. file a menu review, of what needs
> to be conveniently available on menu, and what can go elsewhere.

# The menu today (measured: `starter/lazysite/manager/layout.tt`, 0.15.2)

| Group | Entry | Page | Shown when |
| --- | --- | --- | --- |
| Content | Files | /manager/files | always (locked without the grant) |
| Content | Navigation | /manager/nav | always (locked without the grant) |
| Content | Appearance | /manager/appearance | always (locked without the grant) |
| Content | Extension Manager | /manager/plugins | always |
| Content | Extension Config | /manager/plugin-config | always |
| Access | Users | /manager/users | always |
| Access | Groups | /manager/groups | always |
| Access | Sessions & keys | /manager/sessions | always |
| System | Site settings | /manager, /manager/config | always |
| System | Domains | /manager/domains | always (locked without the grant) |
| System | Cache | /manager/cache | always |
| System | Backups | /manager/backups | always |
| System | Audit log | /manager/audit | always (locked without the grant) |
| System | Connectors | /manager/connectors | always (locked without the grant) |
| System | Handlers | /manager/handlers | always (locked without the grant) |
| System | Data tables | /manager/data | the data extension is enabled |
| System | Visitor statistics | /manager/stats | the stats extension is enabled |

Submissions has no entry. It opens from a "Submissions" button in Extension
Config (`plugin-config.md`, `?submissions=<store>`) and from each file-type
handler's row on Handlers. A single submission opens at /manager/submission from
a notice's link (SM938). Notices are reached from the bell (SM951: currently
inert).

# Proposal for ruling

The test applied: is it used on most visits by the person running the site, or
at setup and when something changes? Placement below is that judgement, made
from the pages' purposes; there is no usage measurement to support it.

| Ref | Change | Why |
| --- | --- | --- |
| M1 | **Submissions gets its own page and a menu entry**, first group: every form's submissions, the quarantine filter, newest first, linked from notices | The daily task the request names; today it is three clicks into an extension's configuration |
| M2 | **The first group becomes "Site"**: Submissions, Files, Navigation, Visitor statistics (when enabled) | What an operator opens on an ordinary visit |
| M3 | **A "Setup" group**: Appearance, Extensions, Handlers, Connectors, Data tables (when enabled), Domains | Set once, revisited when something changes |
| M4 | **Extension Manager and Extension Config become one entry, "Extensions"**, with the configuration as a tab or section of the same page | Two entries for one subject; the config page is where Submissions hid |
| M5 | **Handlers leaves the top level** - kept in Setup, or reached from each form (and from Extensions) | The request: not used every day |
| M6 | **Access and System keep their entries**: Users, Groups, Sessions & keys; Site settings, Cache, Backups, Audit log | Already grouped by purpose; rarely visited but must be findable |
| M7 | **Locked entries stay visible** with the lock and its reason, as today | A hidden entry cannot tell an operator what to ask for |

# Questions for the ruling

1. Accept M1-M7 as a set, or which to change?
2. M5: Handlers in Setup, or off the menu and reached from forms and Extensions only?
3. Should the Submissions entry show an unread count, as the bell does?

# Ruling (2026-10-07)

The release manager: "accept M1-M7, handlers off menu, yes unread count."

1. M1-M7 as proposed.
2. M5: Handlers leaves the menu; it is reached from each form and from
   Extensions.
3. The Submissions entry shows an unread count.

# Built (n265)

The menu (`starter/lazysite/manager/layout.tt`):

| Group | Entries |
| --- | --- |
| Site | Submissions (with the count), Files, Navigation, Visitor statistics (when enabled) |
| Setup | Appearance, Extensions, Connectors, Data tables (when enabled), Domains |
| Access | Users, Groups, Sessions & keys |
| System | Site settings, Cache, Backups, Audit log |

- M1: `/manager/submissions` (`starter/manager/submissions.md`) lists every form
  (form-list) with its count and a link to its handlers, and shows a form's rows
  newest first with the quarantine filter; each row opens `/manager/submission`.
  The viewer MOVED from `plugin-config.md`, which keeps no copy;
  `plugin-config?submissions=<store>` redirects to `?store=<store>`. Gated on
  `read_submissions`, now derived for the menu by the processor.
- M4: one entry, "Extensions", lit for both `/manager/plugins` and
  `/manager/plugin-config`; each page links to the other and to Handlers.
- M5: Handlers is off the menu, the palette and the start-page choices; reached
  from each form on Submissions (`/manager/handlers?form=<name>` opens its card),
  from Handlers' own form rows, and from Extensions.
- M7: locks unchanged in shape and reason; Submissions has its own.
- The count: `notices` answers `unread_by_type` from the same per-operator marks
  (SM938 D3); the bell draws it into the entry when the account holds
  `notifications`, and moves it when a notice - or a row's Open - is followed,
  on Mark all read and on Dismiss. Opening the page marks nothing.
- Found: the bell sent `notices-seen` as a GET, which the API refuses as a
  write, so no mark it made was kept. It is a POST now.
- The command palette lists exactly what the menu links to, under the same
  conditions; sentences that send an operator to the extensions page by name
  say "Extensions page".

Tests: t/unit/manager/202 (the menu rendered for every grant and none, the
palette, the one viewer, the redirect, newest first), 203 (the count through
the API, per operator, gated), 204 (the count in headless Chromium), with 180,
201 and 178 following the moved code. Twenty-eight sabotages, each caught (two first drawn too narrow, then widened).

# Done when

The menu matches the ruling; Submissions opens from the menu in one click; a
test renders the menu for an account with every grant and asserts the entries
and their order, and one for an account with none asserts the locks.
