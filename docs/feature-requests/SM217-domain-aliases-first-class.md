---
title: "SM217 - First-class domain aliases (several hosts, one content root)"
subtitle: "Expose the engine's shared-content_root capability as a first-class Domains action + list marker, instead of an operator hand-editing two domains to the same folder"
brand: plain
status: partial
status-note: "THE ENGINE HALF SHIPPED 2026-09-28. domain_add_alias reads the canonical domain's content root and registers the new host with it, through domain_add - the serving path is untouched, because two hosts sharing a root is what it already does. domain-alias-add on the control API (manage_domains, audited, API-only for SM238's reason - it IS a domain-add). domains-list marks each row alias_of the first host carrying its content root, DERIVED and never stored so it cannot disagree with what decides what is served; a rootless host reads as an alias of (default) rather than of whichever alias came first. THE FILING UNDERSTATED THE CASE: the hand-copying does not fail when it goes wrong. A typo in the shared path is accepted, the host is provisioned and SEEDED with its own empty folder, and it serves a different site under a name that says it is the same one - measured in t/unit/manager/191 before the action was built. Two things the build decided: the action takes NO content_root and refuses one (a sabotage found it being silently dropped instead, which honours the rule by accident - a caller who passed one would have believed it was used); and `seed` does not pass through, because seeding an alias would write a page into the canonical domain's own content. Three sabotages. THE LIST MARKER SHIPPED 2026-09-29: the Domains list tags a row 'alias of <host>', and ONLY where the shared content root is a NAMED folder. The (default) case is deliberately excluded, because this page had already REMOVED an alias chip whose reason is recorded in its source - it meant 'no content folder of its own', the Content folder column already read 'default site', and being a chip it looked pressable and did nothing. What no column says is that two domains pointing at the same named folder are one site, and that is what the marker says. t/lint/155 pins the narrowing and names the earlier decision, because it is one !== that a tidy would delete. STILL OPEN: the 'Add alias' CONTROL. The action exists and the list marks the result; what is missing is a way to invoke it from the page, and the Add form is the place it belongs rather than another domain's config sheet - which is a change to that form's shape and its own piece of work. The optional CLI verb was not built. ORIGINALLY: Captured 2026-07-27 during the 0.10.1 edge batch, deferred out of it (adjacent to SM185's domains UX, but new scope rather than SM185's own follow-up). The engine ALREADY supports several hosts sharing one content_root (a host with no content_root mirrors the primary; two hosts may point at the same folder); only the first-class UI/API affordance is missing. From the earlier SM155 plan's alias section, never built."
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
