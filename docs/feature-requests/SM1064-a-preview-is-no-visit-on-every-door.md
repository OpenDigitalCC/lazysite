---
id: SM1064
title: "SM1064: a preview is no visit, on every door that renders one"
subtitle: "SM1031 left preview_page out of the access log; preview_public_page, preview_domain and the manager's preview, preview-public and domain-preview each still recorded a visit."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: SM1031's open question ("Not changed"), WORK-PLAN-0154 follow-up
area: stats
status-note: "SHIPPED (0.15.5): preview_public, domain_preview and the manager's action_preview set LAZYSITE_PREVIEW, which the access log leaves out (SM1031); every preview door measured in one rig (t/integration/225). Needs n481's access-log guard."
---

# The question

SM1031 ruled "a saved preview is no visit" and fixed MCP `preview_page`: it
sets `LAZYSITE_PREVIEW`, and `_access_record` (lazysite-processor/access-log.pm)
leaves such a render out. It left open whether the other previews record a
visit, because its probe could not run them in the test rig.

# Why the probe could not run them

`preview_public`, `domain_preview` (lib/Lazysite/Manager/Domains.pm) and
`action_preview` (lib/Lazysite/Manager/Preview.pm) find the processor through
`Lazysite::Manager::Common::processor_path`, which reads `LAZYSITE_PROCESSOR`
or else `$DOCROOT/../cgi-bin/lazysite-processor.pl`. A test docroot has
neither, so the render failed. MCP `preview_page` finds the processor through
`_processor_tool`, which looks beside lazysite-mcp.pl first, so it alone could
be measured. The rig in t/integration/225 names the processor in
`LAZYSITE_PROCESSOR`, as t/integration/59 does.

# What was measured (before the fix)

One rig, one docroot, the first-party access log on (the default). A visitor's
GET to the processor writes one line (the control, run before and after).
Each preview rendered the page, checked by its content, and:

| Ref | Door | Function | Recorded a visit |
|---|---|---|---|
| D-1 | MCP `preview_page` | `_preview_page` | no (SM1031) |
| D-2 | MCP `preview_public_page` | `Domains::preview_public` | **yes** |
| D-3 | MCP `preview_domain` | `Domains::domain_preview` | **yes** |
| D-4 | manager `preview` | `Preview::action_preview` | **yes** |
| D-5 | manager `preview-public` | `Domains::preview_public` | **yes** |
| D-6 | manager `domain-preview` | `Domains::domain_preview` | **yes** |

# The fix

Each of the three functions sets `LAZYSITE_PREVIEW`, as SM1031 does:
`preview_public` and `domain_preview` in the `local %ENV` copy they already
build, `action_preview` as a `local $ENV{...}`. No access-log change: the guard
is SM1031's (n481), so this branch is based on n481.

# Found, not changed

- **`preview_public` sends a domain's page to its Host under the docroot
  path.** `preview_public_page` for `/sites/mine/index` (content root
  `sites/mine`, domain `mine.test`) rendered under `mine.test` with
  `REDIRECT_URL=/sites/mine/index` and answered 404 / not-found. It sets the
  owner's Host (SM441) but does not make the URL owner-relative, the defect
  SM1031 (c) fixed in `preview_page`. Not fixed here; for a ruling.
- **Two ways to find the processor.** `processor_path` (manager modules) and
  `_processor_tool` (MCP) resolve it differently; a deployment whose cgi-bin
  is not the docroot's `../cgi-bin` and which sets no `LAZYSITE_PROCESSOR`
  would render `preview_page` and fail the other MCP previews.

# Tests

- t/integration/225: the control; each of D-1..D-6 renders the page and leaves
  the access-log line count unchanged; the control again.

Before the fix, D-2..D-6 fail (on n481). Sabotage (tmp/sab-n554.sh, backups
in tmp/sab-bak/n554/, restored by cp, cmp clean), each marker removed in
turn: the `preview_public` marker fails D-2 and D-5; the `domain_preview`
marker fails D-3 and D-6; the `action_preview` marker fails D-4.

# Related

[[SM1030]], [[SM1031]], [[SM140]], [[SM282]], [[SM441]].
