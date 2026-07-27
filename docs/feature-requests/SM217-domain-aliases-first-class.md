---
title: "SM217 - First-class domain aliases (several hosts, one content root)"
subtitle: "Expose the engine's shared-content_root capability as a first-class Domains action + list marker, instead of an operator hand-editing two domains to the same folder"
brand: plain
status: candidate
status-note: "Captured 2026-07-27 during the 0.10.1 edge batch, deferred out of it (adjacent to SM185's domains UX, but new scope rather than SM185's own follow-up). The engine ALREADY supports several hosts sharing one content_root (a host with no content_root mirrors the primary; two hosts may point at the same folder); only the first-class UI/API affordance is missing. From the earlier SM155 plan's alias section, never built."
---

# SM217 - First-class domain aliases

## Why

lazysite already serves several hosts from one content root: a registered host
with no `content_root` of its own mirrors the primary site, and two hosts may be
pointed at the same `content_root`. But there is no first-class way to say "this
host is an alias of that one" - an operator must add a second domain and manually
set its `content_root` to match, and the Domains list then shows the two as
unrelated peers. The relationship is real but invisible, and easy to get subtly
wrong (a typo in the shared path silently forks the content).

## Design

Convenience action + list marker over the existing shared-`content_root`
mechanism - no engine change to the serving path:

- **`Lazysite::Manager::Domains`**: a `domain_add_alias($host, $of)` that
  registers `$host` with the SAME `content_root` as an existing domain `$of`
  (host-unique; `content_root` intentionally shared). Per-domain
  theme/layout/nav overrides still apply per host, so an alias can differ in
  presentation while sharing content.
- **Control API**: a `domain-alias-add` action (`manage_domains`, `%MUTATING`,
  audited, names the host) beside `domain-add`.
- **`domains-list`**: each row gains an `alias_of` marker - a host whose
  `content_root` equals another registered domain's, so the UI can group aliases
  under their canonical domain with an "alias of X" tag rather than listing them
  as separate domains.
- **`starter/manager/domains.md`**: an "Add alias" affordance on a domain row
  (pre-fills the shared `content_root`); aliases render indented / tagged under
  their canonical domain.
- Optional CLI: a `lazysite-domains alias <host> <of>` verb mirroring the action.

## Tests

- An alias host serves the canonical domain's content (extends
  `t/integration/18-domains-served.t`).
- `domains-list` marks an alias row `alias_of` its canonical domain.
- The action is classified in the cap-gate, audit and write-path guards, as every
  new mutating action is.

## Notes

- Scope: host-unique, `content_root` deliberately shared - the whole point. A
  later "detach alias" (give it its own copy of the content) is a separate,
  larger operation and out of scope here.
- Relationship to SM185 (domains + site-package UX): adjacent, but SM185's own
  follow-up set is empty and shipped; this is a new capability, tracked on its
  own.
