---
id: SM980
title: "SM980: An inline auth_groups list failed open"
subtitle: "`auth_groups: [a, b]` was not read by the gate, so the page carried no group restriction; quoted `auth:` and `payment:` values did the same. The access keys now have one reading, and a value that still cannot be read refuses the page to everyone."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-11
raised-by: the dev inbox, 2026-10-11-an-inline-auth-groups-list-fails-open.md (a members' area on a local 0.15.3 site)
area: security
status-note: "SHIPPED (PENDING): ruled 2026-10-11, Parse it + fail closed. auth_groups is read as a flow or block list on every reader; an auth_groups, auth or payment value that cannot be read answers 403 to everyone with a log line naming the key, is in no listing, and lazysite validate reports it. Lint 220 pins the validator's copy. t/integration/125."
---

# What was wrong

Reported: a page with `auth: required` and `auth_groups: [feedback-readers,
sysops]` and a `db:` binding was served, rows and all, to a signed-in member of
neither group (200). Rewritten as a block list, the same member got 403.
`lazysite validate` raised nothing.

## Root cause

The gate reads a page's access keys through the processor's single-pass peek,
`_peek_md` (`lazysite-processor/auth.pm`), not through the render parse. It read
`auth_groups` only as a block list - `^auth_groups\s*:\s*$`, then indented
`- name` lines - so `auth_groups: [a, b]` matched nothing, `groups` stayed
empty, and `check_auth` applied no group restriction. The render parse
(`front-matter.pm`, `parse_yaml_front_matter`) did not read the flow list either.
The siblings had the same shape: `auth` was read as `^auth\s*:\s*(\w+)`, so
`auth: "required"` (quoted) or `auth: [required]` read as no value and fell to
`auth_default`; an unknown value (`auth: members`) read as an unknown level that
enforced nothing; `payment` was compared to the exact string `required`, so
`payment: "required"` or `payment: Required` served the page free.

## Reproduced on main (41967751)

`tmp/sec-evidence/sm980-probe2.pl` against an export of main
(`sm980-probe2.main.out`), anonymous / signed-in non-member / member:

| Front matter | main | after |
| --- | --- | --- |
| `auth: required` + `auth_groups: [readers, sysops]` (reported) | 302 / **200 + body** / 200 | 302 / 403 / 200 |
| ... `auth_groups: readers` (bare name) | 302 / **200 + body** / 200 | 403 / 403 / 403 |
| ... `auth_groups: []`, `auth_groups:` (none), `[readers, sysops` (unclosed) | 302 / **200 + body** / 200 | 403 / 403 / 403 |
| `auth: "required"` | **200 + body** / 200 / 200 | 302 / 200 / 200 |
| `auth: [required]`, `auth: members` | **200 + body** to everyone | 403 / 403 / 403 |
| `payment: "required"`, `payment: Required` | **200 + body** (free) | 402 |
| `payment: required` + `auth_groups: [readers]` | 402 for the member too | 200 for the member, 402 others |

t/integration/125 run against main fails 69 assertions
(`sm980-t125.main.out`).

# The ruling

Release manager, 2026-10-11, "Parse it + fail closed":

parse the YAML flow list `[a, b]` the same as the block list on EVERY reader of
auth_groups (processor front-matter parse, the auth gate, MCP/API/validator
readers - inventory them; mind ADR 0001 marked copies and lints that pin them);
any auth_groups value that still cannot be read as a list of group names fails
CLOSED (403 for everyone, log line naming the key); `lazysite validate` reports
it. Also check sibling security keys (auth, auth_users if any, payment keys, acl
front matter) for the same flow-list fail-open, and fix within the same rule.

# The fix

- **One reading.** `_access_keys_read($fm)` (`lazysite-processor/front-matter.pm`)
  reads `auth`, `auth_groups` and `payment` from a page's front matter, and the
  gate's peek (`auth.pm`, `_peek_md`) and the render parse both call it. It reads
  what YAML makes unambiguous: a flow list or a block list (indented, or at the
  key's own column), one level of quotes on a value or a name, any case, a
  trailing `# comment`. It answers `unreadable => { key => why }` for anything
  else: a bare name (a string to YAML, not a list), an empty list or no value
  (names nobody), an unclosed list, an empty entry, a name outside letters,
  digits, `.`, `_`, `-`, a value and an indented list together, a key given
  twice; an `auth` other than `required`, `optional`, `none` or `manager`; a
  `payment` other than `required` or `none`.
- **Fail closed.** `check_auth` refuses a page with any unreadable access key:
  403 to everyone, signed in or not (the login page alone stays public), and a
  WARN line `access key unreadable - page refused to everyone key=... why=...`.
  The scan (`_scan_hidden`) and the registries (`_registry_hidden`) leave such a
  page out, for every requester.
- **Every reader.** Inventory, by grep of the tree: the gate's peek and
  `check_auth` (auth.pm); the payment gate (gates.pm, `peek_payment`, which reads
  `payment` from the same peek, and the auth_groups bypass it merges from
  `peek_auth`); the scan and registry gates (sources.pm, `peek_auth`); the render
  parse (front-matter.pm). Nothing in `lib/`, `lazysite-mcp.pl`,
  `lazysite-manager-api.pl` or the tools reads `auth_groups`, and nothing writes
  it. The validator (`Lazysite::Validate`, behind `lazysite validate` and MCP
  `validate_page`) gains `read_access_keys`, a MARKED COPY of the reader (ADR
  0001: it cannot load the processor), and reports each unreadable key as an
  issue (`access-key-unreadable`). **t/lint/220** runs both readers over the same
  texts, a seeded generator and pages read back through the gate's peek.
- **Siblings.** `auth` and `payment` are read and fail closed by the same rule.
  There is no `auth_users` key and no ACL front matter (rules live in
  `acls.json`); the other `payment_*` keys are scalars the gate does not decide
  on.

# Behaviour changes

- `auth_groups: [a, b]` now restricts the page, as the block list always did.
- A page whose `auth_groups`, `auth` or `payment` the engine cannot read answers
  403 to everyone and is in no listing, where it was served (in most cases to
  everyone). Notably a single bare name, `auth_groups: admins`, is refused -
  write `[admins]` or a `- admins` line. `auth: true` and `payment: false` are
  refused the same way.
- `auth: "required"` and `payment: "required"` (quoted, any case) now gate.
- Access keys are read from the front matter only: a page that does not open
  with `---` declares none (the peek used to read an `auth:` line from the top of
  such a page's body).

# Found, not changed - ruled 2026-10-12, built as [[SM993]]

Release manager, 2026-10-12, Findings 3+4, "Fix both as recommended":
auth_groups always implies sign-in (auth: optional + auth_groups -> anonymous
refused, as auth: required); `auth: manager` on a content page (outside the
manager path) is unreadable -> refuses everyone, logged, and `lazysite
validate` reports it (extend SM980's single reader and its marked copy; lint
220 keeps the copies equal). A paid page keeps `auth_groups` as its payment
bypass list (SM993 says why).

- **`auth_groups` binds only a signed-in request unless `auth: required`.** With
  `auth: none` (the default) or `optional`, `check_auth` returns before the group
  test for an anonymous visitor, so an anonymous visitor gets a page that a
  signed-in non-member is refused (403). Measured (`sm980-probe2b`):
  `auth: optional` + `auth_groups: [readers]` - anonymous 200 with the body,
  non-member 403. `starter/docs/frontmatter.md` says "the user must be signed in
  and in at least one to view the page", which the code does not do.
  Recommended: `auth_groups` present implies `auth: required` (the documented
  meaning), or the docs say otherwise.
- **`auth: manager` gates only under the manager path.** On any other page it is
  read and enforces nothing: measured 200 with the body to an anonymous visitor.
  Recommended: refuse it outside the manager path as unreadable, or treat it as
  `required` plus the `ui` capability.

# Evidence

t/integration/125 (reproduction first, 69 assertions fail on main; all pass
after), t/lint/220 (the pin), t/unit/processor/81 (a fixture's bare-name
`auth_groups` became a list). Sabotage: 13 cases (`sm980-sab*.out`), each bit;
the first run found the registry rule unasserted on a page whose `auth:` hid it
anyway, and a page with no `auth:` was added.
