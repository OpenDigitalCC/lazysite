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
status-note: "SHIPPED (PENDING) on n749: design_guide in lazysite.conf, validated as a same-site path; the two layouts pages carry the line when it is set. t/unit/processor/180."
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
  backslash. Anything else (a full URL, `//host`, markup, a space) is `''`, and the
  line is left out. The processor holds its own copy of the rule (ADR 0001: the render
  path loads no modules).
- A host whose alias lines give it a content root of its own gets no line: the path
  names a page in the primary's content. An alias serving the primary's content keeps
  it.
- configuration.md and reference.md document the key.

# Tests

- **t/unit/processor/180** (new): set, both pages carry the line linking the path;
  unset, neither does; eight invalid values give no line and none of the value reaches
  the page; a host with its own content root gets none; and the processor's copy of the
  rule answers as `sanitise_next` does for twelve values.

With the processor's assignment removed (the raw conf value reaching the template), the
invalid subtest fails. With the line removed from layouts.md, the set subtest fails.

# Open

- Whether a domain with its own content root should be able to name its own guide
  (an `alias.<host>.design_guide` line or a `domain_set` key). Not built: the
  ruling names a per-site setting, and the alias whitelist is held by SM1200's test.
