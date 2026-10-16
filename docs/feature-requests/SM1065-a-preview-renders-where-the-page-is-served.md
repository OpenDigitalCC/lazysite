---
id: SM1065
title: "SM1065: a preview renders a page where its site serves it"
subtitle: "preview_public and the manager's preview sent a domain's page to its Host under the docroot path and answered 404; every single-page preview now asks one helper for the Host and the URL."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: SM1064 ("Found, not changed"); covered by the release manager's ruling on SM1031, "Fix all three"
area: manager
status-note: "SHIPPED (0.15.5): Domains::served_at gives the owning domain's Host and the URL it serves the page at; preview_public, the manager's action_preview and MCP preview_page and its draft render through it (t/integration/226). domain_preview had no mismatch. The two processor lookups are left as they are; see below."
---

# The defect

SM441 made the page previews render a domain's page under the Host of the
domain that owns it, so the per-Host overlay supplies its layout, theme and
nav. It left the URL at the page's docroot path. Under that Host the processor
resolves the URL against the domain's own content root, so
`/sites/mine/index` (content root `sites/mine`, domain `mine.test`) looked for
`sites/mine/sites/mine/index` and answered 404: a published page reported as
one no visitor sees. SM1031 (c) fixed it in MCP `preview_page` with the
arithmetic written inline; SM1064 found it still in `preview_public`.

SM1031 (c) had a second half: a primary page asked while the request carries a
domain's Host (the manager opened on that domain's own name) inherited the
Host, was resolved against the domain's content root, and the domain's page of
the same name came back in its place.

# What each preview did (reproduced before the fix, t/integration/226)

| Ref | Preview | Function | Domain page by docroot path | Primary page under a domain's Host |
|---|---|---|---|---|
| P-1 | manager `preview-public`, MCP `preview_public_page` | `Domains::preview_public` | **404 / not-found** | **the domain's page** |
| P-2 | manager `preview` | `Preview::action_preview` | **404 page** | **the domain's page** |
| P-3 | manager `domain-preview`, MCP `preview_domain` | `Domains::domain_preview` | n/a: renders `/` under the named Host, which is where that domain serves its home page | n/a |
| P-4 | MCP `preview_page` and its draft | `_preview_page`, `_preview_draft` | correct (SM1031 (c)) | correct |

# The fix

`Lazysite::Manager::Domains::served_at($rel)` returns the owning domain's Host
(`''` for the primary), the URL that domain serves the path at, and the tie
count. It is built on `content_root_for_path`, the same walk the aliases and
the host lookup use. `preview_public`, `action_preview`, `_preview_page` and
`_preview_draft` all render through it: the owner's Host and the owner-relative
URL for a domain's page, and no Host at all for a primary page, never the
request's. MCP's two inline copies of the arithmetic are gone.

`preview_public` reports `rendered_as_host` as the owner, or `(default)` (the
name `domains_list` gives the primary) for a primary page. It used to report
the inherited request Host there, which for a manager opened on a domain's
name named the wrong site.

# Not changed: two ways to find the processor

`processor_path` (Common.pm, used by `preview_public`, `domain_preview`,
`action_preview`) takes the directory of `LAZYSITE_PROCESSOR`, else
`$DOCROOT/../cgi-bin`. MCP's `_processor_tool` looks beside lazysite-mcp.pl
first, then `$DOCROOT/../cgi-bin`.

One function could serve both: candidates in order `dirname(LAZYSITE_PROCESSOR)`,
beside the running CGI, `$DOCROOT/../cgi-bin`, first that exists. It is left,
because it changes what installed sites do:

- The nginx examples and the Hestia templates set `LAZYSITE_PROCESSOR` only
  for the processor and the manager API, never for lazysite-mcp.pl. So on an
  install whose cgi-bin is not the docroot's `../cgi-bin` (install.pl's own
  example is `--cgibin /usr/lib/cgi-bin`), MCP `preview_page` renders and MCP
  `preview_public_page` and `preview_domain` shell a processor that is not
  there. Unifying fixes that, and it is a behaviour change on those installs.
- "Beside the running CGI" from inside a module needs `$0` (the manager
  modules have no `__FILE__` beside the processor), and MCP resolves its own
  path through `abs_path`, so a symlinked cgi-bin entry would resolve to a
  different directory under one rule than the other.
- 38 test files set `LAZYSITE_PROCESSOR` or reach `processor_path`; some rely
  on a docroot with no processor. The change needs the whole suite and a check
  of each packaged layout (apache, nginx, hestia `.install`), which is a
  night's run, not a precheck.

For a ruling: whether the MCP previews that use `processor_path` failing on
such an install is a defect to fix (the unification above, as its own branch).

# Tests

- t/integration/226: the control (`domain-preview` renders the domain's home
  under its Host); `preview-public` for `/sites/mine/index`, `/sites/mine/`,
  `/sites/mine` and `/sites/mine/about` renders the page, 200, visible, under
  `mine.test`; MCP `preview_public_page` the same; the manager's `preview` for
  `/sites/mine/about.md` and `/sites/mine/index.md`; the primary's `/about`
  asked under `mine.test` through all three renders `PRIMARY-ABOUT`, never the
  domain's `MINE-ABOUT`; MCP `preview_page` still agrees.

Before the fix subtests 2-5 fail (404, and `MINE-ABOUT` for the primary's
page). Sabotage (tmp/sab-n556.sh, backups in tmp/sab-bak/n556/, restored by
cp, cmp clean): `served_at` returning the docroot path fails every domain-page
case in 2-4 and 6; `preview_public` keeping the inherited Host fails its
primary cases; `action_preview` keeping it fails its.

# Related

[[SM1031]], [[SM1064]], [[SM441]], [[SM436]], [[SM282]].
