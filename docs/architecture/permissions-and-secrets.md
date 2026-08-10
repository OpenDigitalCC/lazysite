---
title: "lazysite - permissions and secrets"
subtitle: "Who a caller is, what they may do, what enforces it on each surface, and where every secret lives"
brand: plain
standard-margins: true
---

# Why this document exists

The permission model was documented in pieces: `security.md` covers
authentication and per-page auth, `capability-map.md` lists the capabilities,
`access-control-model.md` compares the two access-control mechanisms. None of
them says how the whole thing fits together, and the August 2026 adversarial
review found several defects whose common shape was **two surfaces disagreeing
about the same question** - a folder ACL that governed the public path and not
the authoring channels, a blocklist carve-out that WebDAV refused and the control
API allowed, a ceiling that one caller applied and another skipped.

A model held only in the code is a model that can differ from itself. This is the
one place that states it.

**It is descriptive, not aspirational.** Where the implementation and the older
documentation disagree, this records what the code does and says so.

# Identities

Every request resolves to exactly one identity before any authorisation happens.

`local`
: The **operator sentinel**. Not an account - it means "the CLI, run directly by
  someone with shell access on the host". Every surface treats it as
  unrestricted. Since SM268 it is a reserved username: no account may be created,
  renamed to, or seeded as `local`, because an account by that name inherits the
  sentinel's authority everywhere.

a named account
: A row in `lazysite/auth/users`, authenticated by password (cookie channel) or
  by credential token (API / MCP / WebDAV).

anonymous
: No credential. Reaches only the public read path - except in unsecured mode,
  below.

## How each surface establishes identity

| Surface | Mechanism |
|---|---|
| Manager UI | Signed `lzs_session` cookie → `lazysite-auth.pl` validates it and sets `X-Remote-User` / `X-Remote-Groups` + `LAZYSITE_AUTH_TRUSTED=1` |
| Control API | The same trusted headers, or a `Bearer` credential token |
| MCP | A `Bearer` credential token |
| WebDAV | HTTP Basic, its own credential check |
| Public read path | The trusted headers when present; otherwise anonymous |

**The trust marker is load-bearing.** The processor and the manager API both
refuse client-supplied `X-Remote-*` headers unless `LAZYSITE_AUTH_TRUSTED=1` is
set, which only the auth wrapper does after validating the cookie. This is why
every front-end config routes through `lazysite-auth.pl` and never at the
processor directly: routing at the processor produces a request with no usable
identity, and everything downstream then behaves as if nobody is signed in.

# Capabilities

A capability is a named permission. An account holds the **union of its groups'**
capabilities - there are no per-account grants (SM095 removed them).

- `lazysite/auth/groups` - group membership, `groupname: user1, user2`
- `lazysite/auth/groups-settings.json` - what each group GRANTS

`Lazysite::Auth::Settings::caps_for($user)` is the single resolver. Every surface
consults it and only it. Groups may **nest** (a group listed as a member of
another), and `caps_for` follows the closure, so capabilities are inherited
transitively.

The current set is in `docs/reference/capability-map.md`; it is generated, so
that file rather than this one is authoritative for the list.

## Two capabilities that are not like the others

`ui`
: Grants the manager interface. Deliberately **separated from `api`/`mcp`**: one
  group must not carry both, so interactive access is never reachable from a
  remote channel. Enforced when the grant is made and again by the transport
  gate.

`manage_users`
: The delegation capability. A holder can create accounts and edit groups. It is
  NOT the operator: since SM195 a holder is bounded by the ceiling below.

## The grant ceiling (SM195)

A non-operator may confer a capability only if they **hold** it, or an operator
has put it in one of their groups' `grantable` set:

```json
{ "client-admins": { "manage_users": 1, "grantable": ["mcp", "api"] } }
```

`grantable` is **operator-only** to set. Grant authority is conferred from above
and never self-assumed; a delegate that could widen its own would have no ceiling
at all.

Removing a capability needs no authority - de-escalation always reduces
privilege.

**The ceiling currently covers one verb.** It gates `group-settings-set`. It does
not gate `group-add`, `group-nest`, `token` or `claim-create`, each of which can
raise privilege by another route (SM268 H8). That is a known gap, not a design.

# The five planes, and what enforces what

| | Manager UI | Control API | MCP | WebDAV | Public read |
|---|---|---|---|---|---|
| Identity | cookie | cookie or token | token | Basic | anonymous or trusted headers |
| Capability gate | `%ACTION_CAPS` | `%ACTION_CAPS` | per-tool `cap` | per-verb | n/a |
| Path containment | `validate_path` | `validate_path` | `validate_path` | `sanitise_path` | `realpath` + docroot |
| Scope (`dav_scope`) | `@REQUEST_SCOPES` | `@REQUEST_SCOPES` | scope union | `authorise` | n/a |
| Per-file ACL | `Auth::Acl` | `Auth::Acl` | `Auth::Acl` | `Auth::Acl` | processor's copy |
| Reserved areas | blocklist | blocklist | blocklist | blocklist | never served |

Two things are worth knowing about that table.

**`Auth::Acl` and the processor's copy are deliberately separate.** ADR 0001
keeps the render path module-free, so the processor carries its own
implementation of the read decision. They must stay in step; `t/lint/31` pins
them. Folder scope existed in only one of them until SM268 H3, which is exactly
the failure this arrangement risks.

**WebDAV is the strictest surface** and the reviewers named it the correct model:
it applies the blocklist on reads as well as writes, and puts MOVE/COPY
destinations through the full authorisation chain after decoding. Where the
planes disagree, WebDAV is usually the one that is right.

# Access control on content

Two mechanisms, and they answer different questions.

**`auth:` front matter and `auth_default:`** - publication. Does this PAGE
require a login, and from which groups. Evaluated on the public read path only.

**`lazysite/auth/acls.json`** - per-path access. Who may read or write THIS path.
Consulted by all four authoring channels, and since SM223 by the public read path
as well.

An ACL entry is keyed by a docroot-relative path, and may name a **folder**, in
which case it covers everything beneath it. The longest matching entry wins - but
only entries carrying a non-empty list for the mode being decided take part, so
an entry with just an `owner` cannot override an enclosing folder's `read` list
(SM268 H10).

```json
{
  "private":            { "read": ["@editors"] },
  "private/brief.pdf":  { "read": ["alice"] }
}
```

- no entry → allowed. `auth_default` does not reach files; protecting one is an
  explicit act.
- an entry with no list for the mode → allowed. An owner is not a restriction.
- `draft: true` on an entry → hidden rather than gated: 404 rather than a login
  bounce, and absent from every listing.

A store that exists but cannot be parsed **fails closed** on the public path
(SM268 H12): the site refuses loudly rather than publishing everything silently.

# Secrets: what exists and where

Everything lives under `lazysite/auth/`, which is mode `2770` - group-writable by
the web user, **no world access** - and denied by every front-end config.

| File | Mode | What it is | Consequence if disclosed |
|---|---|---|---|
| `.secret` | 0660 | HMAC key for session cookies and CSRF tokens | **Forge any session, including the operator's** |
| `users` | 0660 | Password and credential-token hashes | Offline cracking; the file is also the token store |
| `groups`, `groups-settings.json` | 0660 | Membership and grants | Discloses the privilege map |
| `user-settings.json` | 0640 | TOTP secrets, expiry, account metadata | Defeats two-factor |
| `acls.json` | 0660 | Per-path access lists | Discloses what is protected and to whom |
| `sessions.jsonl` | 0660 | Live sessions: user, time, IP, UA, session id | Operator roster + their addresses |
| `revoked.json` | 0660 | Revoked session ids | Revocation could be undone |

Three properties worth stating because defects have turned on them:

- **`.secret` is the crown jewel.** It signs sessions, so anyone who reads it
  forges the operator. SM268 C2 was serious precisely because a site package
  could be made to carry it.
- **`users` is both password store and token store.** Issuing a credential
  REPLACES the account's hash, so `token <user>` is not additive - it destroys
  the existing password. That is why the credential path needs a ceiling
  (SM268 H8).
- **Nothing here is encrypted at rest.** It is protected by filesystem
  permissions and by not being served. That is an accepted trade-off for
  self-hosting, and it is why the reserved-path guards matter so much.

# First run, and unsecured mode

The intended first-run flow is the **CLI**:

```bash
perl tools/lazysite-users.pl --docroot <docroot> setup-manager
```

That creates a `manager` account in a manager group (or issues a self-service
setup link with `--link`), and hands the credential to the operator. The packaged
Hestia deploy runs it automatically.

Until it has run, no group grants manager access, and the code takes that as
"unsecured / dev". **What that actually means is stronger than the older
documentation says.** `security.md` describes it as "any authenticated user has
manager access". The implementation
(`lazysite-manager-api.pl:287-291`) skips the authentication check entirely and
assigns the `local` operator sentinel:

```perl
$auth_user = $ENV{HTTP_X_REMOTE_USER} // '';
if ( $site_secured && !$auth_user ) { respond({ error => "Authentication required" }); exit }
$auth_user ||= 'local';
```

So on an unsecured site the manager API is reachable **with no credential at
all**, as the operator. That is a materially different statement from the one in
`security.md`, and this document is the accurate one.

Two consequences follow:

1. The window between install and `setup-manager` is an open manager. In the
   packaged flow it is momentary; in a manual install it lasts until the operator
   runs the command.
2. The state is recomputed per request from group settings, so a site that has
   been secured for a year becomes indistinguishable from a fresh one if its
   groups lose `ui`, `manage_users` and `manager` - which a `manage_users`
   delegate can currently arrange (SM268 H9).

The existing lockout guard ("refusing to remove the only manager group") covers
the `manager` flag only, not `ui` or `manage_users`, so it is a half-built guard
rather than an absent one.

# Known gaps

Tracked in `SM268`. At the time of writing: the ceiling covers one verb of five
(H8); a delegate can induce unsecured mode (H9); and several medium findings
remain, including `grantable` following direct membership while held capabilities
follow the nesting closure - so operator-set grant authority on a parent group
does nothing.

# Related documents

- `docs/reference/capability-map.md` - the generated capability list (authoritative)
- `docs/architecture/security.md` - authentication, headers, input handling
- `docs/architecture/access-control-model.md` - why there are two mechanisms
- `starter/docs/auth.md` - the operator-facing guide
