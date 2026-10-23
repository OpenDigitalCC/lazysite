---
id: SM1223
title: "SM1223: a binding passes the caller's idempotency key to OOM"
subtitle: "An offline queue that flushes on reconnect cannot tell whether a cut-off request reached Odoo, and a repeat wrote twice. The page now sends an Idempotency-Key per queued item; a repeat answers as OOM answers one, with the first result."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: "the OOM Lab expense app (inbox 2026-10-17, archive 2026-10-18; triage 32-3), ruled by the release manager 2026-10-20"
area: odoo
status-note: "SHIPPED (0.16.1) on n709: the Idempotency-Key header (8-128 chars) is hashed with the binding and who sent it into OOM's idem, on run, approve and apply, in process and through oomd; a repeat is the first result. t/unit/odoo/96, 97, 98."
---

# What happened

The OOM Lab expense app queues its writes offline and flushes them on reconnect. A
flush that is interrupted and sent again gave Odoo the same expense twice, because a
binding offered no way to say "this is the same request". OOM 0.38's `idem => KEY`
on `run`, `approve` and `apply` is exactly that, and lazysite did not carry it.

# The ruling

"build the pass-through (page-chosen key -> OOM idem, scoped to binding and person,
format-checked, recorded)" (tmp/rulings-2026-10-20.md, OOM Lab questions).

# What OOM does with a key (vendored 0.38, `Odoo::Ops::Service`, `Odoo::Ops::Runs`)

- A key is up to 128 printable characters, made by the caller. It is held per
  (instance, login, key) in the runs folder's `.idem` registry, one locked file each.
- A request whose key already made a run is answered with that run, `repeat => 1`:
  the plan while the run is open, the result once it was applied (nothing is sent to
  Odoo again), a failed result included. The same key with another operation or other
  parameters is `refused/idem-mismatch`. A key from another login never answers.
- A key is free again when its run is closed, withdrawn or removed; lazysite removes
  plans and runs after seven days (`$PLAN_KEEP_DAYS`), so that is how long a key lives.
- OOM scopes a key by the login it runs as. A connection binding runs as one shared
  login, so lazysite has to scope by person itself.

# What shipped

- **The key is the `Idempotency-Key` request header** (chosen over a body field: a
  queue sends one request per item, the multipart request has no common body, and a
  batch would otherwise share a field). One call per request; a batch with the header
  is refused. Format: 8 to 128 characters, letters, digits and `. _ : -`, starting
  with a letter or a digit; refused `invalid` before anything is sent. A binding that
  only reads, and a caller who is nobody, are refused.
- **Scoped**: OOM is given `lz1-` and the sha256 of the binding, the account or the
  visitor key's hash (for a session binding, nothing: OOM adds the Odoo uid), and the
  caller's key. Another person's, another visitor's, or another binding's same key is
  another key. The caller's own key reaches neither OOM nor the call record.
- **Every path**: through oomd the key is sent on the run, and on the approve and the
  apply of an `apply: immediate` binding (OOM binds them to the one run). In process
  lazysite takes OOM's own claim (`Odoo::Ops::Runs->idem_claim`) on its plan folder
  and answers a repeat before planning again. The plan folder of a keyed run is
  named from the key, so a repeat finds the plan it made. A confirm uses the key its
  plan was made with (the plan keeps it), so a confirm sent twice answers the first
  result with `repeat: true` instead of `applied`; a plan made with none takes one at
  its confirm; another key than the plan's is refused.
- **Recorded**: the call record has `idem` (the derived key) and `repeat`. A repeat
  is `answered`.
- **Answers**: a repeat is `ok` with `repeat: true`; a key reused with other
  parameters is `refused` (OOM's `idem-mismatch`); a withdrawn plan's key is
  `refused`.
- The browser helper takes `{ idempotencyKey }` on `write` and `confirm` and keeps it
  across its retries. starter/docs/odoo.md has the section "A write sent twice".

# Tests

- t/unit/odoo/96 (OOM's fake Odoo): a repeat does not write twice (and without a key it
  does); other parameters under the key are refused; two accounts, two visitors and
  two bindings with one key do not collide and each one's repeat is a repeat; bad keys
  are refused whole; plan, repeat of the plan, confirm twice, a key at the confirm; the
  record; a session binding scoped to the Odoo user across two sign-ins; the endpoint
  header, a bad header, a batch.
- t/unit/odoo/97 (the real oomd): the same, with oomd's own `.idem` registry holding the key.
- t/unit/odoo/98: the helper's header, kept across a retry.
