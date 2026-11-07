---
id: SM1356
title: "SM1356: schedules: weekly hours, exceptions and dated items"
subtitle: "Opening hours set once through a wizard, holidays and closures added as exceptions, and items that show until a date and then hide themselves."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-06
raised-by: "release manager (SM1350 discussion)"
area: data
status-note: "SHIPPED (PENDING, 0.16.8) on n773 with ruling 164: schedule: true tables, schedule: blocks, time_zone, the expiry, shows_from/shows_until, the schedule-exceptions job. Wizard definition left for the restack (SM1355)."
---

# Proposed

- **A schedule:** weekly opening periods (several a day allowed) plus exceptions (a date or date range: closed, or different hours) in the site's time zone. Set through a wizard (SM1355).
- **Rendering:** blocks for the week's hours, "Open now / Opens at 12:00" and the next exception. A page showing "now" is cached only until the next change of state.
- **Dated items:** any data row may carry `shows_from` and `shows_until`. A row past its date stops showing, with no update needed.
- **Search data:** the schedule feeds SM1357's opening hours.

# Questions for ruling

1. Should exceptions be kept after they pass, or removed after a set time?

Ruled (164): an exception is removed once its date has passed, provided the log keeps
the trail (the removal and the exception it removed are recorded, so the history can be
read back).

# Shipped

## A schedule is a declared table, not a schedule file

Chosen: a table whose descriptor says `schedule: true`. Why, against a schedule file:

- **The doors already exist.** A table is written through the manager's data page,
  `save_data_row` (MCP), `data-row-save` (control API) and the data endpoint, each
  already gated, audited and tested; a schedule file under `lazysite/` would have needed
  a door of its own on every surface (every general write channel refuses `lazysite/`).
- **The gate already exists.** A table is published by `public:` and read through
  `Tables::resolve_binding`, so a schedule is shown to whoever may read it and to nobody
  else, by the same rule as every other table.
- **It travels.** The rows are in the store, so a backup, a site package and a restore
  carry them with no new artefact; SM1355's row history (n772) records their changes.

The engine gives a schedule table its fields (`Lazysite::Data::Schedule::schedule_fields`):
`kind` (`period` or `exception`), `day`, `opens`, `closes` (HH:MM, 00:00 to 24:00; a period
closing before it opens runs past midnight), `date_from`, `date_until`, `closed`, `note`;
key the automatic id. A descriptor may declare fields of its own beside them and may not
redeclare them. A row the schedule could not read is refused at the write on every door
(`Tables::_write_prep` and `import_rows`): a time not HH:MM, a period with no day, an
exception neither closed nor with hours, a range ending before it starts.

## Time is the site's

`time_zone:` in `lazysite.conf` (new) names a zone from the host's zoneinfo; the
arithmetic is POSIX's `mktime`/`localtime` under it, so summer time is the zone's own
rule (tested across both of Europe/London's 2026 changes). Unset is UTC; a name the host
does not know is UTC, logged, and named by `lazysite check`.

## Blocks a layout renders

`schedule:<table>` in a page's `tt_page_var` (or `lazysite.conf`, for every page) gives
`label` ("Open now until 17:00", "Opens at 12:00", "Opens tomorrow at 09:00", "Opens
Monday at 09:00", "Closed"), `open`, `until`, `next_open`, `week` (seven days and their
periods), `today` (with any exception applied), `next_exception` and `exceptions`. Read
as the visitor through the table's gate; every value escaped as a `db:` value is.

## Cached until the next change of state

The schedule's `expires` is the next opening or closing or the next local midnight,
whichever is sooner. The render records it in its dependency record (`@<epoch>`) with the
table's change stamp (`=<path>`, SM1357); the cache serves no render past it on either
branch (a page's `ttl:` included) and the response's `max-age` is held under it. A
schedule page is not live: it is not rendered again in between.

## Dated rows

A table may declare `shows_from` and `shows_until`, each a `date` (a day in the site's
zone) or a `datetime` (an instant, UTC). `resolve_binding` - every page binding and the
data endpoint - leaves out a row outside its window (`SQLite::_where`, bound values; the
list, `_total` and `.count` agree) and returns `expires`, the next moment a row enters or
leaves it, which the page records as its expiry. The `manage_data` surfaces list every row.

## Passed exceptions (ruling 164)

The daemon job `schedule-exceptions` (hourly, `needs => manage_data`) calls
`Schedule::sweep_passed`: every exception whose last day is before today in the site's
zone is written to the **audit trail** - action `data-schedule-exception-removed`, target
`<table>/<id>`, the row as JSON in the line's detail field - and then deleted.
`Schedule::removed_exceptions` reads the trail back. The audit trail rather than the row
history because SM1355's history (n772) was not on this base; at the restack the delete
can go through `Manager::Data` as well, so the row history holds it too. With
`audit_trail: off` the job removes nothing and says why.

## The wizard definition

SM1355's wizard format (n772) is not on main at this base, so no wizard definition ships
here. For the restack: a `lazysite/db/wizards/opening-hours.yaml` over a `schedule: true`
table, one step per field above - `kind` (choice), then for a period `day` (choice),
`opens`, `closes`, and for an exception `date_from`, `date_until`, `closed` (yes/no),
`opens`/`closes` when not closed, `note` - each `when` on `kind`.

Tests: t/unit/data/85, 86, 87; t/unit/processor/185.
