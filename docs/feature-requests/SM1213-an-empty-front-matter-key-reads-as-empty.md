---
id: SM1213
title: "SM1213: an empty front-matter key reads as empty"
subtitle: "The render parse read `title:` with no value as taking the next line, so the key on that line was lost. It opened no gated page - the gate reads each line for itself - but it did let a raw page serve the text/html it declared, past the ADR 0006 downgrade. The value is on its own line now, and the downgrade reads api: and raw: as the render does."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: "SM1209's audit (n697): the page front-matter scalar reader at lazysite-processor/front-matter.pm:382 and lib/Lazysite/Manager/Common.pm:1129 and :2289"
area: security
status-note: "SHIPPED (0.15.15) on n701: an empty page front-matter key no longer takes the key line below it (renderer, page_form, raw_html_page_refusal); an indented continuation still does. No gated page opened. The ADR 0006 downgrade now reads api:/raw: as the render does: `api:` above `true`, `api: \"true\"` and a quoted \"text/html\" were served verbatim as text/html."
---

# What happened

SM1209's audit (n697) found the page front matter's scalar reader written as
`^(\w+)\s*:\s*([^\n]+)$` with `/mg`, in three places:

- `lazysite-processor/front-matter.pm:382`, the render parse (parse_yaml_front_matter);
- `lib/Lazysite/Manager/Common.pm:1129`, page_form, the manager's marked copy of it
  for the form a page binds;
- `lib/Lazysite/Manager/Common.pm:2287-2293`, raw_html_page_refusal, reading `api:`,
  `raw:` and `content_type:` with the same `\s*`.

The `\s*` after the colon runs over the newline, so a key with no value took the next
line as its value, and the key on that line was lost:

    title:                 title = 'subtitle: Hello'
    subtitle: Hello        subtitle: missing
    auth: required         auth = 'required'

# Does it open a page?

No. Every reader that decides who gets a page reads the front matter line by line, and
a line cannot reach the next one:

- the gate: lazysite-processor/auth.pm, `_peek_md` (line by line) and
  `_access_keys_read` (front-matter.pm, split on newlines) for auth, auth_groups,
  addresses, addresses_deny and payment;
- check_auth, check_payment, the protected flag and the cache write in
  lazysite-processor.pl (1289-1363, 1381, 1438-1440) take everything from that peek,
  never from the render parse;
- the scan and registry filters (sources.pm `_scan_hidden`, `_registry_hidden`; acl.pm
  643) and the app's offline list (app.pm `_app_page_fault`, SM1197) ask the same peek.

Proved against the real processor (t/integration/305, before and after the fix, and
tmp/n701-probe.pl in the worktree). Signed out, a page with `title:` above `auth:
required` answers 302 to /login, twice (the second request would be the cache's);
above `auth_groups: [admins]` or the block form, 302, and 403 to a signed-in member
outside the group; above `payment: required`, 402; above `addresses: [office]`, 403;
and `auth:` with nothing after it, 403 to everyone (SM980). No body reached a refused
request, a member's render answered `no-store`, and no such page was written to the
page cache. On a site with `auth_default: required`, `title:` above `subtitle: none`
stays gated and `auth:` above a bare `none` is refused to everyone; only `auth: none`
written as such opens a page. No value appears where none was written.

# What it did open: the ADR 0006 downgrade

The render decides whether a page is served verbatim (pipeline.pm 865-871: `api:` or
`raw:` true, read by the render parse); the peek decides whether its declared content
type is downgraded from text/html, XHTML or SVG to text/plain (pipeline.pm,
peek_content_type, reading `_peek_md`). The two read the front matter differently, so
a raw page could be served as the HTML it declared:

    api:                         render: api = 'true', the body verbatim, no layout
    true                         peek: no api, so content_type stood
    content_type: text/html      served: Content-type: text/html, <script> verbatim

and two spellings that need no empty key: `api: "true"` or `raw: 'true'` (the render
strips one pair of quotes, the peek's line test did not), and `content_type:
"text/html"` (the peek kept the quotes, so the downgrade did not match and the header
went out as written). Measured before the fix: each of the four was served verbatim
as text/html with the script in it; `api: true` with `content_type: text/html`
was downgraded, as t/integration/27 holds.

How much this exposes is bounded by what an ordinary page already allows: a Markdown
page's `<script>` block reaches the browser through the layout as text/html today
(convert_md keeps script blocks, and the CSP hashes inline scripts). What the bypass
adds is a whole response with no layout around it. It is still the boundary ADR 0006
names as mechanically enforced, so it is fixed here.

# What shipped

- One scalar reader, `_front_matter_scalars` (front-matter.pm), line by line:
  `\A(\w+)\h*:\h*(.*)\z`. A value never comes from a key line below it. A key with no
  value takes the next non-blank line only when that line is INDENTED - YAML's
  continuation, which SM976 Q15f made the engine's reading of `form:` / `  leads` and
  which t/lint/219 and t/unit/manager/211 hold. Otherwise it is no value: left out of
  the page's meta, and a later empty key clears an earlier one, as YAML's null does,
  so `meta_desc:` still falls back to the subtitle. A quoted empty value (`""`) is an
  empty string.
- page_form reads `form:` the same way; t/lint/219 still runs both over the same texts.
  t/unit/manager/211's R4 and R5 (`title:` or `né:` above `form: r4`) pinned the old
  reading, under which neither page bound its form; both bind it now, in the processor
  and the walker alike, so a caller scoped to that domain reaches it.
- raw_html_page_refusal reads each value on its own line, strips one pair of quotes
  and takes the last `content_type:`, so it refuses the pages the engine downgrades.
- `_peek_md` also marks `api`/`raw` when the render's reading says true, and strips one
  pair of quotes from `content_type:`. The line test stays: wider is the safe direction.

Tests: t/unit/processor/147 (empty, spaces, a tab, CRLF, a blank line
below, a later empty key; the renderer, page_form, Validate::parse_front_matter and the
two access-key readers on the same texts; the scan's `search: false`; the manager's
refusal) and t/integration/305 (the gated pages above, the default-gated site, the raw
page in each spelling, the rendered title). Both fail on the old code (52 assertions)
and pass on the new; the indented continuation still binds. Sabotage: the three files
restored, both fail again (147 in all four subtests, 305 in two of four).

# Every reader looked at

| Reader | Shape | Affected |
|---|---|---|
| front-matter.pm parse_yaml_front_matter, scalar loop (382) | `\s*` over the newline | yes - fixed |
| Manager/Common.pm page_form (1129) | marked copy of the same | yes - fixed |
| Manager/Common.pm raw_html_page_refusal (2287-2293) | `\s*` with /m | yes - fixed |
| auth.pm `_peek_md` (ttl, api, nocache, raw, camera, admin_bar, theme, content_type, payment_*, tt_page_var, db/odoo triggers, query_params) | line by line | no; api/raw/content_type disagreed with the render - fixed |
| front-matter.pm `_access_keys_read` (auth, auth_groups, addresses, addresses_deny, payment) | split on newlines | no |
| Validate.pm read_access_keys (marked copy, t/lint/220) | split on newlines | no |
| Validate.pm parse_front_matter (validate_page, MCP read_page, list_pages, audit) | split on newlines, empty is '' | no |
| Validate.pm camera_value | line by line | no |
| app.pm `_app_page_fault` (SM1197) | the peek | no |
| Manager/Config.pm `_app_offline_page_fault` | read_access_keys + lines | no |
| sources.pm `_scan_hidden`, `_registry_hidden`; acl.pm 643 | the peek | no |
| lazysite-processor.pl check_auth, check_payment, protected flag, cache write | the peek | no |
| registries.pm resolve_scan and scan_pages (`search:`, scan fields) | the render parse | yes, through it - `title:` above `search: false` listed the page as searchable; fixed with it |
| front-matter.pm register, tags, query_params, tt_page_var, sections blocks | anchored on `key:\s*\n` (a block opener, on purpose) | no |
| lazysite-mcp.pl 3166, the `sections:` component scan | `\s*` with /mg inside the block | not access; left |
| Capabilities.pm `_doc_meta` (docs index) | line by line | no |
| tools/lazysite-check.pl | reads no page front matter | n/a |

# Not done

- The same `\s*`-over-a-newline shape outside page front matter, none of it deciding
  access: plugins/form-smtp.pl:217 and Handlers.pm:1170-1202 (handler settings),
  lazysite-processor.pl:1772 (`content_root:` in lazysite.conf). Left as they are.
- `api: true` above `api: false` (the render: false; the peek: api) and `API: true`
  (the peek is case-blind) still disagree, in the safe direction: the page is rendered
  through the layout and sent as text/plain or JSON.
- Whether an ordinary page's `<script>` should reach the browser is ADR 0006's wider
  question, not this one's.
