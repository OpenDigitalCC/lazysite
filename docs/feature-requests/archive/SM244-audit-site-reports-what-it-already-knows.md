---
title: "SM244 - audit_site does not report what the site already knows about itself"
subtitle: "Starter demo pages were advertised to search engines from a fund's domain, one of them publishing demo credentials. The front matter that identifies them has existed all along and nothing reads it."
brand: plain
status: shipped
status-note: "IMPLEMENTED in the 0.10.3 edge line (2026-08-08, commit 5615e62). Reported by the sjm-claude-code site agent 2026-08-08 from repairs on MCP-built sites. Verified: starter pages carry `provenance: lazysite-starter` in their front matter, and no code anywhere reads that key. Small, and the first item has a live disclosure edge to it."
---

# SM244 - audit_site does not report what the site already knows

## Why

On a fund's live domain, the agent found `/lazysite-demo`, `/payment-demo`,
`/payment-members-demo` and `/members` still public - and `/members` was
publishing demo credentials. The stock `/docs/` tree (28 pages of lazysite's own
documentation) and a `/lazysite-studio/` sales page were being advertised to
search engines: **28 of 31 sitemap URLs were not the site's own content.**

Starter pages carry `provenance: lazysite-starter` in their front matter -
verified present on `starter/members.md`, `starter/payment-demo.md` and
`starter/payment-members-demo.md`. Nothing reads that key anywhere in the
codebase. The site knows exactly which pages are demonstration scaffolding and
has no way to say so.

This is the same shape as the rest of this release line: a fact the platform
holds and does not surface. Here the cost includes a small live disclosure -
demo credentials on a public page belonging to a fund.

## What to add to `audit_site`

`_audit_site` already walks every page, reads its front matter and body, and
reports categories. Three additions, all from data it is already holding or one
cheap check away.

### Starter-provenance pages still published

Report any page carrying `provenance: lazysite-starter` that is registered in
`sitemap.xml`. Registration is the sharp end: a demo page nobody links to is
untidy, and a demo page advertised to search engines from a client's domain is a
different matter.

Report the count alongside the total, because "28 of 31 sitemap URLs" is the
number that makes the problem obvious, and no single page does.

### Stale registry entries after deletion

Deleting a page leaves it in `sitemap.xml` / `llms.txt` until the TTL expires.
Not MCP-specific, but agents delete more than people do, so it surfaces more
often now. Report registered URLs with no corresponding source.

### Retired URLs with no alias

The standing rule is that every old URL gets an `aliases:` entry on its successor
at conversion time. `audit_site` can report pages whose predecessor URL is
reachable in the content history but appears in no `aliases:` block - which is
the check a person is currently doing by memory. Pairs with SM243's
alias-on-rename: that prevents new instances, this finds the existing ones.

## Why not just delete the starter pages on install

Tempting and wrong. They are genuinely useful on a fresh install - they
demonstrate forms, payment and members areas, which is what they are for. The
defect is that nothing tells an operator they are still there when the site stops
being fresh. Reporting is the right verb; removal is the operator's call.

There is a narrower question worth separating: whether a page carrying
`provenance: lazysite-starter` should be excluded from `sitemap.xml` by default.
That would fix the disclosure edge at its source and needs its own decision,
because it changes behaviour for every existing site on upgrade.

## Verification

- A site with starter pages in its sitemap reports them, with a count against the
  total.
- A page whose source was deleted but which remains registered is reported.
- A page whose predecessor URL has no alias is reported.
- A fresh install reports its starter pages without implying they are a fault.
- No new category fires on a site that has none of these.

## Not in scope

- Deleting anything. `audit_site` reports.
- Changing sitemap registration by default - noted above as a separate decision.
