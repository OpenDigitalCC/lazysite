---
id: SM1161
title: "SM1161: a scheduled binding runs as an Odoo login of its own"
subtitle: "L5, scheduled half: the operator may give a scheduled binding a named Odoo login and its own API key, held as the connection user's is. A person's key behind the site sign-in is deferred."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-18
raised-by: inbox 2026-10-17-L5-a-person-key-behind-the-site-sign-in (OOM agent, at the owner's request)
area: odoo
status-note: "SHIPPED on n654: Lazysite::Odoo (scheduled accounts, expiry), tools/lazysite-check.pl report_odoo_scheduled_keys; t/unit/odoo/58, t/tools/180. The person-key mode is DEFERRED by the ruling."
---

# What happened

The OOM agent, filed 2026-10-17 as L5 (option M3 of the pocket-portal plan):

> **Scheduled bindings with a configured key.** A scheduled binding runs as a
> named Odoo login with its own key, rather than the connection user, when the
> operator sets one. The audit's actor is `scheduled:<binding>`.
>
> **Issuing and expiry.** OOM's `oom-accounts` issues keys with a duration and
> reports expiry. Whether lazysite shows a key's expiry to the operator
> (`odoo-status`) is lazysite's.

and, for the other half:

> **A key mode for a person's binding.** The person signs in (L3, with L4's
> code), and calls run with that person's own key, held server-side as the
> connection user's and the MCP grants' keys are (0600, written alone, never
> returned, `has_secret` three-state).

The release manager ruled on 2026-10-18: "Scheduled keys now, person keys
later".

# What shipped

A scheduled binding (modes include `scheduled`) may run as an Odoo login of its
own.

- **Setting and clearing.** `odoo-secret-set` / `odoo_secret_set` take
  `scheduled` (the binding id) with `login` and `secret`; `odoo-secret-clear`
  takes `scheduled`. `manage_connectors`, as the connection user's and the
  grants' are. The binding must exist and permit `scheduled`; `scheduled` with
  `grant` at once is refused.
- **Held as the other keys are.** The same writer and reader
  (`Lazysite::Odoo::Secret`): its own `0600` file under `odoo/keys/`, named by a
  hash of the binding, written alone, never returned, never logged. No new
  secret store. `lazysite/odoo/scheduled.json` maps binding to
  `{ id, login }` and holds no secret.
- **`has_secret`** is three-state (`1`, `0`, `null` for an unreadable file) for
  each scheduled key in `odoo-status`'s new `scheduled` list.
- **The run.** A scheduled call with a configured key goes to OOM with that
  login and key; without one it runs as the connection user, as before. A
  configured binding whose key is missing is refused (`no-key`) and a map that
  cannot be read is refused (`cannot-tell`): neither falls back to the
  (likely wider) connection user, as for an MCP grant.
- **Actor.** The call record, the audit trail and OOM's audit name the actor
  `scheduled:<binding>` for such a run, and the call record's `login` is the
  Odoo login it ran as.
- **Expiry.** OOM 0.27 reports a key's expiry through `core.whoami`, which lists
  the login's own key rows with `expiration_date` on Odoo 18 and later. It does
  NOT say which row is the key in use, so lazysite does not guess: a login with
  one key row shows that key's date (`exact`); with several, all dated, the
  latest date as the bound the held key cannot outlast (`latest-of`); with
  several and one undated, no date (`unknown-which`); on an Odoo that gives keys
  no date, `not-reported`. `odoo-status` reads this live for each held key and
  records the date in `lazysite/odoo/scheduled-expiry.json` (dates only).
  `lazysite check` reads that record, with no call to Odoo, and warns when a
  key expires within 14 days or has expired; an unread or unreported expiry is
  said at ok.

# Not built

A person's key behind their site sign-in (the first item of the inbox note) is
deferred by the ruling. The scheduled-account map and the key store are shaped
by the binding id, so a person's key would be a third map beside them, not a
change to these.

# Left open

- The expiry is read when an operator opens `odoo-status`, not by the daemon, so
  `lazysite check` is as fresh as the last time the status was asked.
- No manager page draws the key controls: like the connection user's and the
  grants' keys they are control API and MCP actions.
