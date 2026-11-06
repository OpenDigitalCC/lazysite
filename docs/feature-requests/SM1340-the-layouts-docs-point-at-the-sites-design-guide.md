---
id: SM1340
title: "SM1340: the layouts docs point at the site's design guide"
subtitle: "The engine's /docs/layouts and /docs/ai-briefing-layouts are the same on every site, so they could not name the guide a site publishes for its designers. A per-site setting, design_guide: /path, makes both open with a \"This site's design guide\" line linking it."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-05
raised-by: "the lazysite.io site agent (inbox 2026-11-05, the shipped layout docs do not point at the design guide); ruling 79"
area: docs
status-note: "SHIPPED (PENDING) on n749: design_guide in lazysite.conf, validated as a same-site path, and per domain as alias.<host>.design_guide (ruling 114); the two layouts pages carry the line when it is set. t/unit/processor/180."
---

# What was asked

Ruling 79 (2026-11-05, Q11, triage T-41): a per-site `design_guide: /path`; the
engine-served layouts doc and ai-briefing-layouts show "This site's design guide" when
it is set, and nothing when it is not. lazysite.io sets it.

lazysite.io publishes a guide for AI designers with a downloadable design kit. Its
footer links /docs/layouts and /docs/ai-briefing-layouts; neither links back, so an
agent that starts from the docs, as the briefings tell it to, never finds the guide.
A shipped doc cannot name it: it is one site's page.

# What shipped

- Engine-served docs already render through Template Toolkit with the site's
  `lazysite.conf` keys as variables (SM1284 serves them through the ordinary render
  path), so no new mechanism was needed: the two pages test `[% IF design_guide %]`.
- The processor sets `design_guide` itself after reading the conf, to the value only if
  it is a same-site path under the rule `Lazysite::Util::sanitise_next` applies to
  `?next=`: a leading `/`, then letters, digits, `_`, `-`, `.` and `/`, no `//`, no
  backslash. Anything else (a full URL, `//host`, markup, a space) leaves the
  variable unset, and the line is left out; so does no key, so a site without one
  renders with the stash it had (t/unit/processor/113 holds the stash). The processor holds its own copy of the rule (ADR 0001: the render
  path loads no modules).
- A host whose alias lines give it a content root of its own gets no line: the path
  names a page in the primary's content. An alias serving the primary's content keeps
  it.
- Ruling 114 (2026-11-06, Q46): a domain may set its own guide with
  `alias.<host>.design_guide: /path`, which overrides the site-level `design_guide`
  for that host on both pages. `design_guide` joins the alias whitelist (and SM1200's
  test of it, and configuration.md's list). The domain's own value is a path in its
  own content, so it holds whatever the domain's content root; it is held to the same
  same-site rule, and an invalid one is no guide (it does not fall back to the
  site's). A domain without the line falls back to the site's as before, or to none
  when it has a content root of its own; unset on both is no line. Only the conf key:
  `domain_set` and the Domains page do not carry it, like the CSP and app keys.
- configuration.md and reference.md document the key and the per-domain override.

# Tests

- **t/unit/processor/180** (new): set, both pages carry the line linking the path;
  unset, neither does; eight invalid values give no line and none of the value reaches
  the page; a host with its own content root gets none; and the processor's copy of the
  rule answers as `sanitise_next` does for twelve values. Ruling 114's subtest: a
  domain with its own line links it on both pages and not the site's, also with a
  content root of its own; a domain without one falls back to the site's; the primary
  keeps the site's and never a domain's; a domain's guide needs no site-level one;
  unset for the domain and the site is no line; a domain's invalid value is no guide.
- **t/unit/processor/146**: the whitelist's intended keys include `design_guide`.

With the processor's assignment removed (the raw conf value reaching the template), the
invalid subtest fails. With the line removed from layouts.md, the set subtest fails.
With `design_guide` out of the alias whitelist, eight assertions of ruling 114's
subtest fail; with the own-guide exemption from the content-root rule removed, the two
content-root assertions fail.
