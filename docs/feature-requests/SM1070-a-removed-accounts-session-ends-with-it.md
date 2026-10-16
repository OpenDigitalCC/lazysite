---
id: SM1070
title: "SM1070: a removed account's session ends with it"
subtitle: "Found by n562, ruled \"Probe, then fix\" 2026-10-13. Removing an account left its signed cookies verifying as that name until they expired: no revocation on remove, and no account check in the cookie verifier."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-13
raised-by: n562 (security review), ruled "Probe, then fix" by the release manager 2026-10-13
area: accounts
status-note: "SHIPPED (0.15.5): the cookie verifier refuses a session whose account is not in lazysite/auth/users (no-account; an unreadable store is cannot-tell), and remove and rename revoke the account's sessions by name before changing anything. Disabled was already refused on every cookie door. t/unit/auth/55-56, t/integration/243."
---

# The ruling

The release manager, 2026-10-13, on n562's finding, "Probe, then fix": probe
every cookie door on main with a removed, a disabled and an ungrouped account,
then fix both sides - `remove` revokes the account's sessions the way SM1040
does for a password change, and the session check refuses an account that no
longer exists, fail-closed on an unreadable store (SM1024).

# What was wrong

- `cmd_remove` (`tools/lazysite-users.pl`, the one remover behind the CLI and
  the manager's Users page) deleted the account's line, its group memberships
  and its settings row. It wrote no revocation, and with the settings row went
  the `disabled` flag.
- `verify_session_cookie` (`lib/Lazysite/Auth/Session.pm:330` on 02c590bd)
  checked the signature, the expiry, `disabled` (`:396`) and the revocations
  (`:403`). It never asked whether the account existed. It is the only cookie
  verifier in the tree; every door inherits the gap through it:

  | Caller (02c590bd) | Door |
  |---|---|
  | `lazysite-auth.pl:1001` (`handle_request`) | the auth wrapper: the processor's page gate, the manager API, everything it fronts |
  | `lazysite-auth.pl:562` (`_session_identity`) | logout |
  | `lazysite-data.pl:148` | the data endpoint: CSRF token, row writes |
  | `plugins/form-handler.pl:248` | form posts: the rate-limit waiver (SM425) and the delivery actor (SM1018) |

  Not verifiers: `lazysite-processor/gates.pm:219` checks the preview cookie,
  which names no account; `lib/Lazysite/FrontDoor.pm:144` and
  `lazysite-processor/front-door.pm:112` only see that a cookie is present, to
  bypass the static cache.

# The probe

An account `gone` in a group granting `ui`, `manage_content` and `write_data`
signed in for real through the auth wrapper; the cookie was kept; the account
was then changed with the users tool and the cookie replayed through the real
CGIs (the wrapper in front of the manager API and the processor; the data
endpoint and the form handler verify it themselves). Status, what came back, and
the audit trail's actor for each.

On main (02c590bd):

| Door | Removed | Disabled | Groups removed |
|---|---|---|---|
| manager `whoami` | 403 forbidden (no `ui`), audited `gone` | 400 Authentication required | 403 forbidden, audited `gone` |
| manager `read /index.md` | 403 forbidden, audited `gone` | 400 | 403 forbidden |
| manager `save /probe.md` | 403 forbidden, audited `gone`; nothing written | 400 | 403 forbidden |
| manager `me` (/account) | **200, user=gone** | 400 | 200 |
| manager `me-sessions` | **200** | 400 | 200 |
| manager `me-notices` (the bell) | **200** | 400 | 200 |
| manager `me-notices-seen` (a write) | **200, audited `gone`** | 400 | 200, audited `gone` |
| processor `/members` (`auth: required`) | **200, page served** | 302 to sign-in | 200 |
| processor `/editors` (`auth_groups`) | 403 | 302 | 403 |
| data `?csrf=1` | **200, token minted** | 403 not signed in | 200 |
| data row write | 403 (no `write_data`) | 403 anonymous | 403 |
| form post, personal row | **200, rate limit waived, row owned by `gone`, audited `gone`** | 200 anonymous, rate-limited | 200, waived, owned by `gone` |

The removed account's groups and settings had gone with it, so everything that
needs a capability or a group refused it - the manager's `ui` gate (SM1057) and
the data writers. Everything that needs only "a signed-in account" admitted it:
the members' pages, /account, the bell, a data CSRF token, the form waiver, and
a personal row WRITTEN in the removed name. The groups-removed column is right
as it stands: groups are read fresh on every request (SEC-2026-07 M5), and an
account that still exists keeps its member's doors.

**Disabled was refused on every cookie door** - the wrapper, the data endpoint
and the form handler all go through the one chain, which has checked `disabled`
since SM071. No door needed a disabled fix.

A site with no operator group could not be built for the "every account is an
operator" case (SM991's unsecured site) with the users tool: it seeds its default
groups on the first group write, after which the site counts as secured, and the
run came back identical to the secured one. On such a site the fix applies the
same way - the account check comes before any operator decision.

## Exposure on released versions

The same probe against the v0.15.4 tag (25ae5b6e), which has the same verifier
(`lib/Lazysite/Auth/Session.pm:282-353`: disabled at `:345`, revoked at `:350`,
no account check) and the same `cmd_remove`, and predates SM1057's `ui` gate:

| Door | Removed (v0.15.4) |
|---|---|
| manager `whoami` | 200, user=gone |
| manager `read /index.md` | 200 |
| manager `save /probe.md` | **200, file written, audited `gone:create`** |
| processor `/members` | 200 |
| data `?csrf=1` | 200, token |
| data row write | 403 |
| form post | 200, rate limit waived (no actor before SM1018) |

**On every release up to and including 0.15.4, a removed account's cookie
writes content through the manager until it expires** (24 hours by default,
`session_lifetime` up to a year): the cookie door asked only that a session
carried a user, so it wrote any path no rule governs (the SM1057 hole, opened
here by an account that no longer exists). Main closes that write through
SM1057, not through this change, and still admitted the removed account on the
member doors above. The workaround on a released site is to sign the account
out everywhere (Sessions page, or `user-revoke`) BEFORE removing it, or to
rotate the signing secret.

# The fix

- **(b) The verifier asks the account store.** `verify_session_cookie` reads
  `lazysite/auth/users` after the signature and expiry, before the other stores:
  a name not in it is `no-account`; a store that exists and cannot be opened is
  `cannot-tell`, naming `lazysite/auth/users` (SM1024) - never "exists"; an
  absent store is a site with no accounts, which is an answer. Asked first, so a
  removed account answers `no-account` whatever its revocations say. The auth
  wrapper logs `auth: account does not exist`, naming the account.
- **Cost.** One open of `lazysite/auth/users` and a scan that stops at the
  account's line. The wrapper already read the whole store on every
  authenticated request to flag a passwordless account; the verifier now
  returns that flag (`no_password`) from its own read and the wrapper's second
  read is gone, so the wrapper reads the store once, as before. The data
  endpoint and the form handler gain one read.
- **(a) Remove and rename revoke.** `cmd_remove` revokes the account's sessions
  with `Manager::Sessions::revoke_account_sessions` - SM1040's `not_before`,
  nothing kept, legacy cookies included - before it deletes anything; a
  revocation that cannot be written dies with "nothing was changed" and the
  account stands. Every remove goes through it: the CLI, the users tool's API
  (`action => 'remove'`), which the manager's Users page calls. The account
  import has no undo (it stages and applies; nothing removes). `cmd_rename`
  does the same for the OLD name.
- **Why both.** The account check alone ends the removed account's cookies -
  until an account is created under the same name, which would inherit them,
  because a cookie names its account by name. The revocation is what survives
  that; the check is what covers an account deleted by any other means.

# Tests and sabotage

Reproduced first: on 02c590bd `t/unit/auth/55` failed 5/6, `t/unit/auth/56`
10/17 and `t/integration/243` 20/39.

- `t/unit/auth/55` - the verifier: present, removed, a prefix of another name,
  absent store, unreadable store (cannot-tell), disabled and revoked unchanged,
  the passwordless flag.
- `t/unit/auth/56` - remove through the API, the CLI and the manager's users
  action writes the revocation; a cookie of the removed account stays refused
  when the name is created again, and the new account signs in; rename revokes
  the old name; an unwritable revocation removes nothing.
- `t/integration/243` - the probe as a test, through the real CGIs: removed and
  disabled open no door (manager, /account, bell, pages, data token, form
  actor and waiver, no audit entry, no state written, the wrapper's log line);
  groups removed keep the member's doors and lose the group's; the passwordless
  flag reaches the processor.

Four fixtures minted cookies for accounts the store did not hold and are
corrected: `t/unit/auth/12`, `14` and `52` now create them, and
`t/unit/forms/08` created its member with an eleven-character password, which
SM1041 refuses - in silence, behind `2>/dev/null` - so its "member" existed only
in the cookie.

Sabotaged one at a time (backups in `tmp/sab-bak/n564/`, restored with `cp` and
compared with `cmp`):

| Sabotage | Caught by |
|---|---|
| the verifier's account check deleted | 55, 243 |
| an unreadable users store read as "exists" | 55 |
| remove revokes nothing | 56 (243 still passes: the account check covers it) |
| rename revokes nothing | 56 |
| the wrapper drops the passwordless flag | 243 |
| the wrapper does not log no-account | 243 |

`dist/config/bench-baseline.json`: `work_users_tool_statements` 3472 to 3483,
the eleven statements of `_end_every_session` and its two calls.
