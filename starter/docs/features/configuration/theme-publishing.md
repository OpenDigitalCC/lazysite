---
title: Theme and layout publishing
subtitle: Author themes and layouts over WebDAV, preview them, and activate with a safe back-out - on your own or with an automated partner.
tags:
  - configuration
  - template
---

## Theme and layout publishing

SM071 lets a manager (and a delegated automated partner) author themes and
layouts directly: edit the files over WebDAV, preview the result, then
activate it through the control API with validation, a backup, and a clean
back-out. It builds on the [WebDAV endpoint](/docs/features/configuration/webdav)
and the [preview](/docs/features/configuration/themes) feature.

### Capabilities

Three per-user capability flags gate this surface (set with
`tools/lazysite-users.pl set USER KEY on`, or in the manager Users page):

`manage_themes`
: Read, edit, preview, and activate themes.

`manage_layouts`
: The same for layouts. Granted separately - a broken `layout.tt` breaks
  every page, so the structural layer is a higher privilege than themes.

`manage_config`
: Write the small allowlist of `lazysite.conf` keys exposed over the
  control API (the `theme:`/`layout:` pointers are covered by the two
  flags above; this adds the broader allowlist).

### Editing over WebDAV

Themes and layouts live under `lazysite/layouts/`. Over WebDAV they follow
a **per-object** rule:

- The **active** theme and the **active** layout are **read-only** -
  publishing never half-writes what visitors are seeing.
- Any **inactive** theme/layout is **writable** (with the relevant
  capability), so you edit a candidate, then activate it.
- The rest of `lazysite/` (auth, cache, config) stays denied.

`dav_scope` confines *content* publishing only; it does not gate theme or
layout access, which is governed by the capability flags above.

### The content-hash manifest

Every file under `lazysite/layouts/` carries an `lzs:sha256` property on
`PROPFIND`, and the control API's `artifact-manifest` returns the full
per-file manifest plus a combined `digest`. A client uses these to know
exactly what changed and to detect drift before activating.

### Activating (and backing out)

Activation flips the `theme:` (or `layout:`) pointer in `lazysite.conf`
and clears the page cache, but only after:

- **Validation** - a theme needs `theme.json` declaring the active layout
  in its `layouts[]`; a layout needs a `layout.tt` that compiles.
- **A compatible pair** - activating a layout requires the resulting
  (layout, theme) to be compatible; name a compatible theme in the call
  if the current one is not.
- **Optimistic concurrency** - pass the manifest `digest` as `base`; if
  the artifact drifted since, activation returns a 409 conflict.
- **A lock** - the artifact is locked for the transition (423 if held,
  including by a WebDAV client).

The outgoing live theme/layout is **snapshotted** as
`<name>-backup-<UTCstamp>` (itself a selectable theme), pruned to
`backup_retention` (default 3). **Back-out is just activating the
backup** - or any earlier one.

### Automated partners

A partner is an ordinary sub-user driven by an access token rather than a
password. Provision one in a single step:

    tools/lazysite-users.pl partner-create NAME --by PARENT \
        [--layouts] [--config] [--scope /path]

This creates the sub-user with partner defaults (`webdav` +
`manage_themes`), records provenance (`created_by`/`managed_by` = the
creating user), mints a one-time **pairing key**, and prints an onboarding
brief to hand to the partner.

The partner exchanges the single-use pairing key for a short-lived access
token (`token-exchange`), presents it as HTTP Basic auth, and rotates it
before expiry (`token-rotate`). A leaked token self-expires; a spent
pairing key is dead. Disabling the account (`account-disable`, optionally
`--cascade`) revokes access everywhere immediately.

### Rate limiting and the retry contract

Both the WebDAV endpoint and the control API throttle per token with a
token bucket (default burst 200, refill 20/s). When throttled they return
**429**; a held lock returns **423**. Both responses carry a
**`Retry-After`** header - honour it, backing off with a little jitter.

### Control API

The control API is the manager API reached with token auth
(`Authorization: Basic <user>:<lzs_ token>`); it is CSRF-exempt for token
requests and confined to the control-API action set, each gated by the
capability above:

`artifact-manifest`, `artifact-validate`
: Read the manifest/digest; dry-run the activate validation.

`theme-activate`, `layout-activate`
: Validate, snapshot, and flip the pointer (accept `base` for the 409
  conflict check; `layout-activate` accepts `theme` for the compatible
  pair).

`token-exchange`, `token-rotate`
: Bootstrap and refresh the access token.

`account-create`, `account-disable`, `account-enable`, `account-reassign`
: Manage sub-users within your own sub-tree (a manager may only manage
  accounts it is an ancestor of).

### Related

- [WebDAV publishing](/docs/features/configuration/webdav)
- [Themes](/docs/features/configuration/themes) (incl. preview)
- [Layouts](/docs/features/configuration/layouts)
