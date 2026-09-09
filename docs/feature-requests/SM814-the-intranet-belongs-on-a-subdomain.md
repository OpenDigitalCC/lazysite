---
id: SM814
title: "SM814: the intranet belongs on a subdomain, not a folder"
subtitle: "A domain record already separates thirteen settings including theme, layout, nav and the group gate, so a subdomain intranet needs no engine change. The folder approach needs features that do not exist and leaves a per-page burden that has already been got wrong on a shipped build. Recommends the subdomain, and depends on SM813: without a shared sign-in it is defensible on separation grounds but loses the single experience that was asked for."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-09
raised-by: sites agent
area: architecture
---

# The recommendation

An intranet is being specified to ship with every lazysite ([[SM815]]). It can
live in a folder of the main site, as `sovereigncomputing.org` does today, or on
its own subdomain. **The subdomain, and the reasoning is mostly that one of the
two already works.**

Verified here: the domain record does carry the separation claimed -
`allowed_groups`, `content_root`, `is_primary`, `lang_group`, `locked_users`,
`nav_file`, `search_default`, `site_name`, `site_url`, alongside layout and
theme. Every axis an intranet fights the base site on is on that list. And it is
routine rather than exotic: the sites instance serves seven domains, edge nine.

# What the folder approach costs

Six seams on the shipped build, of which the reporter counts three as engine
gaps and three as per-page discipline:

- **Theme, theme configuration, theme varieties.** All three are [[SM812]], and
  the correction there matters to this filing: the per-page `theme:` key exists
  and has since SM120. The workaround that made the configuration inert was
  never necessary, so **the folder approach is one seam better than reported**.
  What remains genuinely absent is folder inheritance.
- **The gate.** Every page needs `auth: required` and a `read:` list. Miss one
  and it is public.
- **Search and indexing.** Every page needs `search: false` and its own
  `register:` handling to stay out of the sitemap and llms.txt.
- **The task index kept by hand**, because `resolve_scan` globs the public tree
  while gating moves content into the private store, so a scan inside a gated
  section matches nothing.

On a subdomain the theme questions are settings, the gate and the search default
are one setting each on the domain record, and only the scan limitation
survives - which the Discuss application avoids by being table-backed.

**The three discipline seams are the argument.** An engine gap is fixed once; a
per-page rule that must hold on every page for ever is got wrong eventually, and
being got wrong here means a private page served publicly.

# What it depends on

The honest cost of a subdomain was a second sign-in, and [[SM813]] measured that
this is a cookie attribute rather than an architecture. **This filing depends on
that one.** The operator's requirement is that the intranet feel like one
experience rather than a second place with its own front door; without a shared
sign-in the recommendation still stands on separation grounds but loses the
thing that was asked for.

That dependency runs one way and should be decided in that order: [[SM813]] is
useful on its own, this is not useful without it.

# What it does not solve

Folder-scoped themes ([[SM812]] item 2) remain worth building. A docs section
that wants a denser treatment, a client area on a marketing site, a campaign
microsite with a short life - none of those wants a second hostname, and the
two should not be traded off against each other.

# Provenance

`inbox/2026-09-09-the-intranet-should-be-a-subdomain.md`. The domain-record
field list was checked against `lib/Lazysite/Manager/Domains.pm`; the theme seam
was corrected against [[SM812]].
