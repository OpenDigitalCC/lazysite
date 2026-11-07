---
id: SM1373
title: "SM1373: an extension's settings read answers only its own keys"
subtitle: "extension-read answered every key in an extension's config file: for bad-url-blocker and log, the site's whole lazysite.conf. It now answers the keys the extension declares, whatever its file."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-06
raised-by: "release manager (triage T-57)"
area: extensions
status-note: "SHIPPED (0.16.6) on n759: extension-read answers only the keys config_schema or config_keys names, password fields still dropped; a cookie session with manage_config only, no token. Register entry confirmed (ruling 140); judged a hardening, not a vulnerability fix, at the 0.16.6 walk (SM1380). t/unit/manager/445."
---

# What happened

`extension-read` (`Lazysite::Manager::Extensions::action_extension_read`) answered
every `key: value` pair in an extension's `config_file`. Two shipped extensions,
bad-url-blocker and log, keep their settings in `lazysite/lazysite.conf`, so a read
of either returned the site's whole main config. An extension with its own file
answered any key in it, including keys its schema never names. Only the
extension's own `type: password` fields were dropped.

# What shipped

- **The extension's own keys.** The answer is the union of the keys the
  extension's `config_schema` names and its `config_keys`, whatever its file.
  The source file is chosen as before.
- **Password fields** are still dropped.
- **Who reaches it is unchanged.** `extension-read` has no `%GATE` line in
  `Lazysite::ControlApi::Actions`, so no access token, MCP client or partner can
  call it; the manager's cookie dispatch asks its `cookie_cap`, `manage_config`.

# Tests

t/unit/manager/445 uses the shipped descriptors against a fixture docroot with a
foreign key (and a foreign password-shaped key) in `lazysite.conf` beside
bad-url-blocker's and log's, and a key outside form-smtp's schema in its own file.
None is answered, and the password field is still dropped. It fails with the change
reverted.

# Security

docs/SECURITY.md, the 2026-11-06 SM1373 entry: Information disclosure narrowed, no
ADR 0007 trigger, confirmed by the release manager (ruling 140). At the 0.16.6
compliance walk (SM1380) it was judged against the vulnerability-handling row: the
reader is a cookie session trusted with the site's settings, and no shipped
extension keeps a credential in `lazysite.conf`, so it is a hardening and 0.16.6 is
not cut security-critical for it.
