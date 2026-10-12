---
id: SM1057
title: "SM1057: a member in no group saved pages through the manager API"
subtitle: "A signed-in account holding no capability wrote any unruled path through action=save, because the manager API's cookie door never asked for the manager (ui) capability. On a domain the writes landed in the primary's tree."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: inbox report 2026-10-12, sites.lazysite.io (tprf-news domain), engine 0.15.4
area: security
status-note: "SHIPPED (PENDING): a non-operator cookie session needs ui (n540); a content write needs manage_content with the file's rule on top (n541), and so does an acl-set creating the first rule on a content path (n542) - both ruled \"Require manage_content\". Unsecured sites unchanged. Affects v0.14.4, v0.15.0-0.15.4. t/integration/220-223."
---

# The report

On sites.lazysite.io (0.15.4), domain `tprf-news.sites.lazysite.io` (content
root `sites/tprf-news.sites.lazysite.io`), the account `ui-tester` is in no
group. Signed in at `/login`, it sent manager-API `action=save` with its cookie
and CSRF token and got 200 for `/post/year_in_perl_2005.md` (a post with an
owner rule), `/search.md` and a new `/post/zz-gate-check-N.md`. `action=read` of
the post was refused. The rules, keyed `sites/tprf-news.sites.lazysite.io/...`,
read back correctly.

# The reproduction

t/integration/220 builds the same site in the rig: a domain with a content
root, rules set through `acl-set` keyed by the content root, a sysop, an
author named in the post's rule, and a member in no group. On main (b5ab1ce4),
with the domain's Host and with none:

```text
save /post/p.md            ok:1 created:1   <docroot>/post/p.md (primary tree)
save /search.md            ok:1 created:0   the primary's own search page
save /post/zz-new.md       ok:1 created:1   new file in the primary tree
save /sites/tprf/post/p.md refused (permission) by the rule
read /sites/tprf/post/p.md ok:1 (no read rule)
read /post/p.md            not found (the report's "read refused")
mkdir, lock, acl-set on an unruled path   ok:1
```

28 of 42 assertions failed on main; all pass with the fix.

# What was true

Neither of the report's readings.

1. "The domain reads its own group settings, finds no manager grant, and
   counts as unsecured." **False.** Every door reads the auth store from the
   engine tree of `DOCUMENT_ROOT`
   (lazysite-manager-api.pl:115, Auth::Acl::_settings_dir), and the Host chooses
   nothing. The login itself proves it: `ui-tester` exists only in the
   instance's store. `_is_operator`'s unsecured clause
   (lib/Lazysite/Auth/Acl.pm:598) never fired.
2. "A save on the host looks up `post/...` while the rules are keyed
   `sites/<domain>/...`." **False as a key mismatch.** Manager, MCP and WebDAV
   paths are docroot-relative on every host (Manager::Common::validate_path,
   lib/Lazysite/Manager/Common.pm:371; lazysite-dav.pl PATH_INFO; lazysite-mcp.pl
   `_resolve_page_path`), and the key checked is the key `acl-set` writes. The
   save of `/post/...` was checked against `post/...` because it WROTE
   `post/...` - in the primary's tree, where no rule governs it. The domain's
   file was never touched, which is why it compared equal afterwards.

The faults:

- **lazysite-manager-api.pl:334-369** - the cookie door's only requirement was
  a non-empty `X-Remote-User`. The `ui` capability, which the `/manager/` pages
  require (lazysite-processor/auth.pm:285 `_is_manager`), was never asked of the
  API. The token door has had its channel gate since SM126.
- **lazysite-manager-api.pl:667-674 and the `if (!_operator())` block** -
  `save`, `delete`, `mkdir`, `move`, `copy`, `file-upload`, `migrate-to-local`,
  `lock`/`unlock`/`renew-lock` carry no cookie capability by design: they
  self-authorise against the file's rule, and `_acl_allows`
  (lib/Lazysite/Auth/Acl.pm `return 1 unless $a`) admits every writer to a path
  no rule governs. `acl-set` on an unruled path lets the caller claim it.

So any signed-in account on any instance could write every unruled path of the
whole docroot, on any host.

# The fix

The cookie door asks for the manager. A non-operator cookie session must hold
`ui` - from the account store (`manager_ui` in its effective settings) or from
the session's groups (`X-Remote-Groups`, set by the auth wrapper), the two
sources `_is_operator` already asks. Refused 403 `forbidden`, audited
`denied: manager channel capability`. An operator, and every account on an
unsecured site, never reaches the gate, so first-run and dev sites are
unchanged. Only `csrf-token` answers before it, and it grants nothing.

# Inventory: writes a cookie session reaches

Every manager-API action now passes the `ui` gate first. After it:

| Action | Gate after `ui` | Verdict |
| --- | --- | --- |
| save, delete, move, copy, file-upload, migrate-to-local | per-file rule (`_acl_denied`, Files.pm) | closed for no-ui; manage_content required (n541) |
| mkdir | none (no user passed, Files.pm action_mkdir) | closed for no-ui; manage_content required (n541); SM992 (n385) adds the rule check |
| lock, unlock, renew-lock | none | closed for no-ui; manage_content required (n541); SM992 (n385) adds the rule check |
| acl-set, acl-remove | ownership / write rule (Files.pm action_acl_set) | closed for no-ui |
| git-restore | manage_content | unchanged |
| cache-invalidate | none (self-healing) | closed for no-ui |
| start-page-set, notices-seen | the caller's own record | closed for no-ui |
| session-revoke, key-revoke, user-revoke, users | bespoke actor gates | closed for no-ui |
| connector-call | the connector's own `callers` | closed for no-ui |
| every other mutating action | its `cookie_cap` / token gate | unchanged |
| WebDAV (any method) | Basic auth only, never a cookie; `webdav` + `manage_content` (lazysite-dav.pl:1702) | not cookie-reachable |
| MCP | bearer/OAuth only; `mcp` + per-tool gate | not cookie-reachable |
| lazysite-data.pl row writes | cookie + CSRF + manage_data/write_data | already gated |

MCP and the token path use the same docroot-relative key as the manager:
t/integration/221 refuses a writer the rule does not name on all three doors,
on the domain's Host and the primary's, for read and write.

# Exposure

Read from the tagged source (tmp/n540-exposure.sh): v0.14.4, v0.15.0, v0.15.1,
v0.15.2, v0.15.3 and v0.15.4 all lack the gate, and all carry the
self-authorising content writes. Earlier lines were not read; the cookie door
has had this shape since the SEC-2026-07 cookie capability gate.

What an operator can do before a patch release:

- create no member accounts (no-`ui` logins) on an instance whose content
  matters, and disable those that exist;
- or put a site-wide write rule on the docroot (`acl-set path=/` with
  `write: [@sysops]` plus the editing groups) so no path is unruled - every
  write then needs a rule naming the writer;
- check the primary tree of an affected instance for files a member wrote
  (on sites.lazysite.io: `search.md`, `post/year_in_perl_2005.md`,
  `post/zz-gate-check-*.md` at the docroot) and the audit trail for `save`
  rows by accounts without `ui`.

# The ruling: "Require manage_content"

The question n540 left open - an account holding `ui` but not `manage_content`
still wrote any unruled path through the cookie door, while WebDAV and MCP
require `manage_content` - was ruled by the release manager on 2026-10-12:
"Require manage_content". Built on n541.

On the manager API's cookie door a content write needs `manage_content`, and
the file's rule still applies on top. The writes are the actions declared
`content_write` in Lazysite::ControlApi::Actions: save, delete, move, copy,
file-upload, mkdir, migrate-to-local, lock, unlock and renew-lock (the
inventory found no other content writer without a capability; git-restore
already needs `manage_content`). The capability is read from the account store
first and the session's groups second, as the `ui` gate reads it. A path in the
engine's own tree (`lazysite/...`) keeps the capabilities that govern it -
nav.conf's `manage_nav`, the layouts' - as WebDAV's content namespace does. An
account with `ui` alone is read-only in the manager. Operators, and every
account on an unsecured site, are unaffected. Refused 403 `forbidden`, audited
`denied: content write capability`.

A rule that names an account no longer lets it write without the capability:
the rule says who may write which file among those who may write content.

## The second ruling: "Require manage_content"

The question left open here - whether acl-set creating the first rule on an
unruled content path should also need `manage_content` - was ruled by the
release manager on 2026-10-12: "Require manage_content". Built on n542.

On the cookie door, an acl-set that creates the FIRST rule on a content path
that has none needs `manage_content` from a non-operator, as the token and MCP
doors already require. Before it, the first rule was authorised by write access
to the file, which an unruled path grants every writer: on n541 a `ui`-only
account created a site-wide rule (`path=/`) writable only by itself, and every
other writer on the site was then refused. The ownership rule for an existing
rule is unchanged - its owner changes it without the capability - and the
engine's tree (`lazysite/...`) is exempt as it is for content writes. The key
checked is the one the action writes: '/' for the site-wide spellings,
otherwise validate_path's rel, normalised. Refused 403 `forbidden`, audited
`denied: content write capability`.

# Tests

n542: t/integration/223 - a `ui`-only account cannot create the first rule
on a page or the site (reproduced on n541: its site-wide rule then refused every
other writer); the owner of an existing rule still changes it; a first rule on
lazysite/nav.conf needs no `manage_content`; a `manage_content` holder creates
one and owns it. Sabotage: no gate fails 223 (9); no engine-tree exemption (1);
an existing rule refused too (1); the site-wide key unresolved (6).

n541: t/integration/222 - a `ui`-only account is refused each of the ten
content writes (reproduced on n540: it saved, deleted, made a folder, copied and
took locks), including a page whose rule names it; it still reads; a
`manage_nav` holder still saves nav.conf by path; a `manage_content` holder
writes an unruled page and is still refused one whose rule does not name it.
t/unit/manager/15's authors and editors groups gain `manage_content`. Sabotage:
no gate fails 222 (28); no account-store half fails 222 (2); no session-groups
half fails 15 (3); no engine-tree exemption fails 222 (1); `save` undeclared
fails 222 (9).

n540:

t/integration/220: the reproduction - save, read, delete, mkdir, lock, move,
copy and acl-set by the member, on the domain's Host and the primary's, each
refused by the new gate; the primary tree and the domain's files unchanged; the
author still saves its post. t/integration/221: reading 1 (a `ui`-only account
is not the operator on either host; the control, an unsecured site, shows the
probe sees an operator) and reading 2 (the content-root key refuses a writer
the rule does not name on the manager, MCP and WebDAV, read and write, on
either host). Twelve fixtures that drove the manager with accounts unable to
open `/manager/` now grant `ui`. Sabotage: removing the gate fails 220 (45);
dropping the account-store half fails 220 (2); dropping the session-groups half
fails t/unit/manager/15 (8).
