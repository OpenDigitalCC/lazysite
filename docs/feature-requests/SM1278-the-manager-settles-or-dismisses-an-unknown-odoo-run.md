---
id: SM1278
title: "SM1278: the manager lists, settles and dismisses an unknown Odoo run"
subtitle: "Rulings 10b and 10c: the manager's Odoo page lists the runs left unknown and still open, an operator says there whether a change was made, and dismissing a run is an operator action that is audited. The control API and MCP have the same three actions."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-23
raised-by: "the release manager, rulings 10b and 10c (2026-10-23)"
area: odoo
status-note: "SHIPPED (0.16.3) on n733: odoo-unknown-runs / odoo_unknown_runs and odoo-dismiss / odoo_dismiss (settle_odoo_writes), odoo-resume / odoo_resume (ALWAYS: the run's binding decides, as for odoo-confirm); the Unknown Odoo writes panel on the Odoo extension's row of the Extensions page. t/unit/odoo/110."
---

# What was asked

- **Ruling 10b**: on the manager's Odoo page, open unknown runs are listed and an
  operator assumes there.
- **Ruling 10c**: dismissing is an operator action, audited.
- **The brief**: assume and DISMISS on the manager, with control API and MCP parity
  per the repo's surface rules and lints.

# What shipped

- **`action_odoo_unknown_runs(%who)`** (`odoo-unknown-runs`, `odoo_unknown_runs`).
  - It lists every plan that ended unknown and is not settled, dismissed or withdrawn,
    newest first.
  - Each run gives its handle, binding, operation, owner label, when, how many,
    oomd or in-process, `person` (a session binding's run, which only the person can
    resume), `resumes`, and the changes still unknown from its journal (seq, key,
    action, model, id). It gives no value and no path.
  - A run of a domain the caller does not reach is left out, by `domain_refusal` as
    `odoo-bindings` asks it.
  - It needs `settle_odoo_writes` at the control API's gate, and again in the engine,
    because MCP calls the same function.
- **`action_odoo_resume($run, $done, $not, %who)`** (`odoo-resume`, `odoo_resume`).
  - It calls SM1275's `resume` with the caller's context, minus any grant's account:
    a resume runs as the run's own account.
  - Gate `ALWAYS`, as for `odoo-confirm`: the run's binding and `resume` decide.
- **`action_odoo_dismiss($run, $reason, %who)`** (`odoo-dismiss`, `odoo_dismiss`).
  - It needs `settle_odoo_writes`. The optional reason is one line of at most 300
    characters.
  - It refuses a run that is not open: `not-found`, `dismissed` or `settled`.
  - It keeps `dismissed {at, by, reason}` in the run's meta, purges the run's file
    bytes, and sends nothing to Odoo.
  - It is one call record (phase `dismiss`, `run`, decision `dismiss`) and one
    `odoo-call` audit line.
  - The run then goes on the plan store's schedule (SM1279).
- **The manager page.**
  - The Odoo extension's row on the Extensions page (`starter/manager/plugin-config.md`)
    gains **Unknown Odoo writes**, an expanding panel like the blocked-address list.
  - The panel is a table: binding, made by, when, and each unknown change, with **It
    was made** and **It was not made** for a change, and **Check again** and
    **Close run** (a dismissal) for the run: t/lint/97 keeps "Dismiss" for a button that loses nothing.
  - A person's run gets Close run alone.
  - Close run asks first.
  - The change keys are held in `window._unknownRuns` and named by index, never
    written into a handler string.
- **Surfaces.** The three actions are in `%GATE` and `%ACTION`, and the MCP tools are
  in `lazysite-mcp.pl`. `settle_odoo_writes` unlocks the list and dismiss on api, mcp
  and ui. The generated `control-api-actions.md` and `capability-map.md` are
  regenerated. The lints' reviewed lists name the new actions with their reasons:
  - 14: the list is a read;
  - 23 and 58: a resume is binding-gated, as a confirm is;
  - 91: run, assume lists and reason are not paths;
  - 92: a resume is a deliberately constant gate;
  - 98: 125 token-reachable actions;
  - 218: neither action is instance-wide.
- **Docs**: `starter/docs/odoo.md`, "On the manager".

# Tests

t/unit/odoo/110:

- the list needs the capability, shows both open runs, the owner, the count and the
  unknown change, and no value or path;
- an operator assumes through `action_odoo_resume`, and a caller with neither
  ownership nor the capability is `not-yours`;
- dismissing:
  - needs the capability, and a reason must be one line;
  - sends nothing and keeps who and why;
  - is not listed or resumable afterwards, and is not dismissed twice;
  - is one record naming the run, the decision and who, and one audit line;
- a dismissed run is pruned on the store's schedule;
- the Extensions page offers the panel and the three actions.

With Odoo.pm and plugin-config.md at SM1279, the file dies at its first subtest (no
`action_odoo_unknown_runs`). With only the page reverted, the page subtest fails.
