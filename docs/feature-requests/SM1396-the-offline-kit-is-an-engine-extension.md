---
id: SM1396
title: "SM1396: the offline kit is an engine extension"
subtitle: "Ruling 53 accepts the offline kit as an engine extension, app-offline, on condition that kept data is owned by login and an item with no owner is nobody's. Built on the asset hooks of SM1369 X5 as their second consumer (ruling 74), with nothing Odoo-specific in core."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "ruling 53 (release manager, 2026-11-04, triage Q8); ruling 74 (D-9); planned as X8 of SM1369, n770"
area: extensions
status-note: "SHIPPED (PENDING) on n770: extensions/app-offline.pl (requires odoo; declares assets/kit.js and the variable app_offline_kit), Lazysite::Ext::AppOffline, the kit; ?csrf=1 answers `owner` (a label of the login) and the identity cookie carries it as `who`; docs under /docs/app and in the layouts briefing. t/unit/extensions/77, 78 (a 127.0.0.1 endpoint stand-in), t/unit/odoo/28, 41."
---

# The ruling

Ruling 53 (release manager, 2026-11-04, triage Q8): the offline kit is accepted
as an engine extension after SM1142, "on condition data is owned by login and an
item with no owner is nobody's". Ruling 74 (D-9) places it straight after X1 and
the asset part of X5, as the hooks' second real consumer, in the exemplar-first
approach of ADR 0009. The layouts catalogue's note that asked for it (triage
T-27) wanted "a script, one template variable, a slot contract" - the shape H-10
gives.

# What was built

The extension
: `extensions/app-offline.pl`, `requires => ['odoo']`, declares one asset
  (`kit.js`, served by the engine at `/assets/app-offline-kit.js`) and one
  template variable, `app_offline_kit`, rendered by
  `Lazysite::Ext::AppOffline::kit_tag` (the payload's one module, named as
  ruling 68 shapes an extension's modules). The variable is the script tag while
  the extension is on and nothing otherwise, because the index names only
  enabled extensions and the processor reads the enabled list again. Enabling
  it with Odoo off is refused by name (X1's `requires`); with Odoo turned off
  afterwards the variable renders nothing and the kit is not served. No
  settings. No layout ships a script.

The kit (`extensions/app-offline/assets/kit.js`)
: Wraps the Odoo browser helper. A connection banner (`data-ls-app-banner`,
  from the browser's online and offline events and from a call that could not
  be made); kept reads (the last good answer to each read through the helper,
  given when the same read fails for want of a network, marked `kept` with
  its time, a region marked `data-ls-app-kept`); a write guard
  (`LazysiteAppOffline.write`: sent at once online with an `Idempotency-Key`,
  queued when offline or when the send was cut off, and a queued change sent
  once, in order, with the same key, so the server never writes twice -
  SM1223); the queue (flushed on `online`, on the page shown again, after a
  sign-in and at load, one flush at a time; an item leaves on any answer and
  stays on a cut-off or a `signin-required`); install and update status
  (`data-ls-app-status`, from `lazysite-app-update`, a tap applies the waiting
  worker); sign-out (drops the person's kept reads; a queued change waits for
  them). The page is told through a `lazysite-app-offline` event.

Owned by login
: `?csrf=1` on the page endpoint answers `owner`, a label of the signed-in
  login: `Session::login_label`, the hash the call records already name a
  sign-in by, never the login. It comes from the identity cookie, which now
  carries it as `who` (derived at the mint from the login OOM gave), or on a
  site whose Odoo sign-in is the site sign-in from the site session's identity
  (`odoo:<login>`); it is absent when nobody is signed in or the identity has
  lapsed. The kit stores a kept read or a queued change under the owner, shows
  and sends for no other login on the same browser, and refuses a change with
  no owner (`no-owner`), keeping it nowhere. The store is localStorage under the
  site's origin; it holds what the endpoint answered and what a page asked to
  send, never a token, a cookie or a password.

The slot contract
: `data-ls-app-banner`, `data-ls-app-show-out`, `data-ls-app-show-in` and
  `data-ls-app-status`, each toggled with `hidden` and marked
  `data-ls-app-state`; named in the layouts briefing and described under
  /docs/app, "The offline kit".

# Choices made

```datatable
columns: Ref | Choice | Taken | The other option
widths: 1cm | 4cm | X | X
text: 3
---
K-1 | How the kit learns the owner | A server label (`owner`, from the identity cookie's `who` or the site session), fetched by the kit from `?csrf=1`; the identity cookie gains one key, a hash the records already use | The kit remembers the login from the sign-in answer in the browser: stale after a sign-in made elsewhere, and names people by what the browser kept
K-2 | The kit's placement | One template variable, `app_offline_kit`, as the brief asks; the asset declares no `inject_when` | `inject_when: data-ls-app-banner`, so the slots alone pull the script in
K-3 | A queued change whose answer is a refusal (4xx, 5xx) | Leaves the queue, and the page is told through the event: an answer came, and the server's own unknown-write handling (SM1277) covers an apply that never finished | Keep it queued and send again, which would resend a change the server refused
K-4 | Sign-out | Drops the person's kept reads; keeps their queued changes for their next sign-in | Drop both
K-5 | A change with a file | Sent when online, refused offline (`offline`), never queued: a file cannot be kept in the store | Keep the file in IndexedDB
```

# ADR 0007

No trigger fires. No new external interface: the kit posts to the existing page
endpoint through the existing helper, with the existing `Idempotency-Key`
header; `?csrf=1` gains one field. No new sign-in method, no new dependency, no
new restricted data: the owner label is the hash the records already carry. The
register entry in `docs/SECURITY.md` is drafted for the release manager's
confirmation, with the one question the identity cookie raises (it now carries
`who`, a hash of the login; test 28 pins the cookie's keys and was changed).
