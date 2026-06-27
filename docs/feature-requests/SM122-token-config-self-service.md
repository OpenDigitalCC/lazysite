---
title: "SM122 - config self-service for manage_config tokens"
subtitle: "Let an agent read (and set a safe subset of) site config"
brand: plain
---

## From the field report

"With manage_config I still could not enable WebDAV (`config-set` rejects
`webdav_enabled` as 'not settable via the API'), and `config-read` is blocked for token
clients, so I could not introspect `layout` / `theme` / `webdav_enabled` to
self-diagnose." Rated **Medium**; reading state is the bigger win.

## Shape

- Allow a token client with `manage_config` to **read** the effective config (at least
  `layout`, `theme`, `webdav_enabled`, `site_name`, `manager_groups`) - an agent that
  can see the active layout/theme and whether WebDAV is on can self-diagnose instead of
  inferring from HTTP codes.
- Allow **setting** a small, safe subset via `config-set` (`webdav_enabled`, `layout`,
  `theme`, `site_name`) - the keys with no injection surface. Keep the rest operator-only.
- Mirror this in `whoami` / the brief so the agent knows what it can read/set.

## Status

Queued. Bounded: a token-readable config-read allowlist + an expanded config-set
allowlist in the control API.

## Status (reconciled)

**SHIPPED in v0.4.40.**
