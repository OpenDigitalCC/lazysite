---
id: SM1000
title: "SM1000: an alias renders from its canonical domain"
subtitle: "A host registered as an alias named itself as canonical: two hosts, one content root, each canonical to itself, and a sitemap in the shared folder that named whichever host regenerated it last."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-11
raised-by: the dev inbox (2026-10-11, an alias host is its own canonical, item 1); WORK-PLAN-0154 P14; ruling of 2026-10-12
area: rendering
status-note: "SHIPPED (0.15.5): canonical_url (the alias_of domain's site_url) drives the injected canonical link and every registry's site_url; the alias keeps its own site_url; _canonical_of is a marked copy of domains_list's derivation (t/unit/processor/102, lint 224)."
---

# The ruling

"Render from the canonical": for a host registered as an alias (alias_of),
canonical link, sitemap and llms.txt addresses use the canonical domain's
address; the alias keeps serving under its own name.

# What changed

**Which domain is canonical.** alias_of is derived, never stored
(`Lazysite::Manager::Domains::domains_list`, SM217): the canonical domain of a
content root is the first row carrying it - the primary, then `alias_hosts` in
order. The processor cannot load that module (ADR 0001), so
`_canonical_of($conf_text, $host)` (lazysite-processor/sources.pm) is a marked
copy, and lint 224 runs both over five confs (shared roots, inherited roots, a
base `content_root`, a reordered `alias_hosts`) and requires the same canonical
host and site_url for every row.

**`canonical_url`.** `resolve_site_vars` sets it after the alias overlay: the
canonical domain's `site_url` (through `resolve_tt_vars`, so `${VAR}`
interpolates as a site_url does), or the host's own `site_url` when it is the
canonical one. Authoritative, like `alias_host`. `site_url` is unchanged: the
alias still serves under its own name and its pages link within it.

**The canonical link.** `_inject_canonical` (layout.pm) builds the link from
`canonical_url`, falling back to `site_url`. A layout that writes its own
canonical link is deferred to, as before, and is documented to use
`canonical_url`.

**The registries.** `update_registries` renders every registry template
(sitemap, llms.txt, the feeds, a site's own) with `site_url` set to
`canonical_url`. A registry lists the pages of a content root and is written
into it, so before this the shared folder's sitemap named whichever host's
request regenerated it. A host with no content folder of its own still
generates no registries (SM110), as before.

# A consequence to confirm

By the derivation, a host with no `content_root` of its own serves the
primary's content and is an alias of the primary - the Domains list already
tags it so. Its canonical link is now the primary's address. That is the same
rule applied to the case where two hosts share the docroot; it is recorded in
WORK-PLAN-0154's open questions in case a chrome-only alias (SM110: same
content, its own theme) is meant to stay its own canonical.

Ruled 2026-10-12, in the release manager's word: "Keep" - a rootless domain
names the primary as canonical. Recorded; nothing changes.

# Tests

t/unit/processor/102: www.canon.test (sharing canon.test's folder) renders
`<link rel="canonical" href="https://canon.test/about">`, its `site_url` is
still its own, `canonical_url` is the canonical domain's, and it is served, not
redirected; canon.test, other.test (its own folder) and the primary are their
own canonical; sitemap.xml and llms.txt asked of the alias name canon.test and
never the alias, and other.test's sitemap keeps its own address. Lint 224.
