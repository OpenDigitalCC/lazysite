---
title: "SM217 - First-class domain aliases (several hosts, one content root)"
subtitle: "Expose the engine's shared-content_root capability as a first-class Domains action + list marker, instead of an operator hand-editing two domains to the same folder"
brand: plain
status: shipped
status-note: "THE CONTROL SHIPPED 2026-09-29 on claude/n199-add-a-domain-as-an-alias, which closes this filing. The last open row was the Add alias CONTROL - the action existed and the list marked the result, but nothing on the page could invoke it, so it was reachable only over the API, which is not where an operator adds a domain. IT IS AN OPTION, NOT A BUTTON, and that is the design rather than an economy: a separate Add alias control would be a second door to the same room. The Add form already asks where this domain's content lives, and the same content as <host> is one more answer to that question, so it sits in the picker that asks it, grouped as Share an existing site. One form, two actions, chosen by that answer - every other field is identical on both paths, because the appearance and language of a second name are still that name's own. THREE THINGS THE FORM MUST NOT OFFER, each already enforced by the engine and each therefore a REFUSAL rather than a visible bug if the page drifted: an alias sends no content_root (domain_add_alias refuses one outright rather than dropping it - which is the distinction that filing's own sabotage earned); an alias never offers seed, because seeding writes a starter page into the canonical domain's content and a checkbox that cannot do what it says is worse than none; and only a domain with a NAMED folder is offerable, because a rootless host serves the default site, which is already the first option in the same select - the same narrowing the row marker got, for the same reason. The preview names the folder being shared and says no folder is created and nothing is copied, where the ordinary path promises to create one; the success line says which of the two things happened rather than Configured for both. t/lint/158, five sabotages - AND THE FIRST FOUND A HOLE IN THE TEST: it asserted aliasOptionsHtml(), which the function's own DEFINITION satisfies, so deleting the line that appends the options to the select changed nothing the test could see and the control would have vanished with every assertion green. It now asserts the call site. t/lint/70 had one pattern widened to match the new body shape, its rule unchanged and re-checked as still biting. STILL OPEN AND OPTIONAL, named so it is not mistaken for an oversight: the CLI verb. The action, the control API, the page and the list all reach this now; a fourth surface wants its own argument. PREVIOUSLY: THE ENGINE HALF SHIPPED 2026-09-28. domain_add_alias reads the canonical domain's content root and registers the new host with it, through domain_add - the serving path is untouched, because two hosts sharing a root is what it already does. domain-alias-add on the control API (manage_domains, audited, API-only for SM238's reason - it IS a domain-add). domains-list marks each row alias_of the first host carrying its content root, DERIVED and never stored so it cannot disagree with what decides what is served; a rootless host reads as an alias of (default) rather than of whichever alias came first. THE FILING UNDERSTATED THE CASE: the hand-copying does not fail when it goes wrong. A typo in the shared path is accepted, the host is provisioned and SEEDED with its own empty folder, and it serves a different site under a name that says it is the same one - measured in t/unit/manager/191 before the action was built. Two things the build decided: the action takes NO content_root and refuses one (a sabotage found it being silently dropped instead, which honours the rule by accident - a caller who passed one would have believed it was used); and `seed` does not pass through, because seeding an alias would write a page into the canonical domain's own content. Three sabotages. THE LIST MARKER SHIPPED 2026-09-29: the Domains list tags a row 'alias of <host>', and ONLY where the shared content root is a NAMED folder. The (default) case is deliberately excluded, because this page had already REMOVED an alias chip whose reason is recorded in its source - it meant 'no content folder of its own', the Content folder column already read 'default site', and being a chip it looked pressable and did nothing. What no column says is that two domains pointing at the same named folder are one site, and that is what the marker says. t/lint/155 pins the narrowing and names the earlier decision, because it is one !== that a tidy would delete. STILL OPEN: the 'Add alias' CONTROL. The action exists and the list marks the result; what is missing is a way to invoke it from the page, and the Add form is the place it belongs rather than another domain's config sheet - which is a change to that form's shape and its own piece of work. The optional CLI verb remained unbuilt at that point. ORIGINALLY: Captured 2026-07-27 during the 0.10.1 edge batch, deferred out of it (adjacent to SM185's domains UX, but new scope rather than SM185's own follow-up). The engine ALREADY supports several hosts sharing one content_root (a host with no content_root mirrors the primary; two hosts may point at the same folder); only the first-class UI/API affordance is missing. From the earlier SM155 plan's alias section, never built."
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
