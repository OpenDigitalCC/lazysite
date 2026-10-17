---
id: SM1140
title: "SM1140: a group is limited by the address it is used from"
subtitle: "Slice C of SM1134: a group's address lists limit only what the group grants, the manager and its API can be limited for everyone, and the machine doors (control API, MCP, WebDAV) judge a token by its own request address."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: release manager, 2026-10-17 (SM1134)
area: auth
status-note: "SHIPPED on n636 (slice C of SM1134; cites SM1138): lib/Lazysite/Auth/AddressScope.pm, Auth::Settings::_group_closure, Auth::Identity, lazysite-processor/acl.pm, the manager API and MCP doors, the users tool's group-settings-set, the Groups and Config pages; t/integration/285, t/unit/auth/64."
---

# What happened

SM1134, ruled in full on 2026-10-17 ("1. yes, 2. yes. 3. yes. 4. yes. 5. yes. 6.
yes."). Two of the rulings are this slice:

> 2. **Groups:** does an address list on a group limit only what the group grants
> (proposed), or sign the member out entirely from other addresses? Ruled: limits
> only what the group grants.
>
> 3. **Machine doors** (MCP, control API, WebDAV): do group and site-wide address
> rules apply to tokens too (proposed: yes; a token is a member of its groups)?
> Ruled: yes.

and the request's own examples: "the operator group only from the office, so a
stolen operator password is no use from elsewhere", and "an instance allow or deny
list for `/manager/` and the manager API, independent of groups".

# What shipped

## A group's lists

A group record in `groups-settings.json` may carry `addresses` (allow lists) and
`addresses_deny` (deny lists), each a list of address-list names (SM1138). When
`Auth::AddressLists::decide()` refuses the request's address for a group, that group
does not count **for this request**: not its capabilities, not its page and file
access (`auth_groups`, `groups:`, an ACL `@group` entry), not operator status, and
nothing reached through it by nesting. Deny wins; an allow list means only those
addresses; a store that will not read denies (the group is left out). The account
stays signed in and keeps whatever its other groups grant.

**Where it is resolved.** Group membership for a request is walked in two places and
the limit is applied in both, so every gate agrees:

- `Auth::Settings::_group_closure`, which `groups_grant_cap`, `groups_are_operator`,
  `caps_for` (`_group_caps`), `effective_groups` and `group_closure` all go through
  (so the capability gates, `account_is_operator`, the per-file ACL closure, domain
  scope and WebDAV's caps);
- the processor's module-free copy `_group_closure` in `lazysite-processor/acl.pm`
  (ADR 0001), which decides through `Auth::AddressScope` loaded on demand and only
  when some group carries a list.

Group names that arrive as names rather than through a walk (the cookie wrapper's
direct groups; a trusted proxy's directory groups, which the page gate and the ACL
read without a closure) are filtered in `Auth::Identity::request_identity`, the one
identity reader. t/unit/auth/64 lifts the processor's walk out of its source and
runs it beside the module's over the same stores and the same request, for an
address inside, outside and denied, and for nesting both ways.

**Nesting.** A blocked group is neither a seed nor a parent, and nothing is reached
through it. A member of a group nested under a limited group holds the limited
group's grants only from allowed addresses; a member of a limited group nested under
an open one holds neither the limited group nor the open group it would reach by way
of it, from outside.

**No request, no address.** The rules apply only inside a web request (`REMOTE_ADDR`
or `REQUEST_METHOD` present). The users tool, the build tools and the scheduler have
no visitor and read the structure whole; the users tool also sets
`Auth::Settings::$ADDRESS_RULES = 0`, because it manages the stores and may have
inherited the manager API's environment. Inside a request an address that cannot be
worked out is a refusal (`no-address`), never a pass.

**The doors that ask the users tool.** The cookie manager reads the caller's
settings from the users tool, an OAuth connector's from `partner-caps`, and a
deployment that names `LAZYSITE_USERS_TOOL` verifies a token there too; the tool
answers what the account is granted, whoever asks from wherever. Each door cuts the
caller's settings back to what the request's address allows
(`Auth::Settings::narrow_caps_to_request`, which only ever removes a capability):
`Manager::Common::_user_caps`, the manager API's token path, and MCP's bearer
verification. WebDAV and the data endpoint call `caps_for` in process and need no
narrowing.

**Setting it.** `tools/lazysite-users.pl group-settings-set GROUP addresses|addresses_deny
NAME,NAME` (`group-set GROUP addresses office` at a shell; an empty value clears).
Operator only, on the same terms as `directory_grants` (SM1135, SM991): `local`, a
member of the operator group, or anyone on an unsecured site; a `manage_users`
holder is refused with "Only a sysop may limit a group by address". Each name must be
a valid list name. Audited as `addresses=office; was ...`. `group-settings-get`
serves both arrays. The Groups page offers the operator two rows of tick boxes, "Only
from" (allow lists) and "Never from" (deny lists), built from `address-lists`.

## The manager, site-wide

`lazysite.conf` `manager_addresses:` and `manager_addresses_deny:` (comma-separated
list names) limit `/manager/` and the manager API for everyone, whatever their groups.

- `/manager/...` (`handle_manager_path`): a refused visitor gets 403 and the sentence
  "This page is not available from your address." on a page that stands alone (the
  same as `_serve_manager_forbidden`, so it renders with a broken layout or theme).
  The sign-in pages are outside the manager path and stay reachable.
- The manager API (`lazysite-manager-api.pl`): refused before anything is verified,
  cookie and token alike, with 403 and `{ok: false, kind: "forbidden", error: <the
  sentence>}`. This is the control API, so a token call from outside is refused.
- Audit: `address-refused manager` and `address-refused manager api`, once per
  address per hour; detail is the reason `decide()` gave and the list names.
- The Config page shows both keys under "Manager user interface" as text fields (it
  has no list chooser) with the names in the note. `config-set` accepts them for a
  cookie session only (a token that could narrow the manager could not be undone),
  requires each name to be an existing list of the right kind, refuses a store it
  cannot read, and refuses a value that would shut the setter's own address out.

MCP and WebDAV evaluate the group rules with the token's own request address; the
site-wide manager rule is applied to the manager and its API, which is what it
names, and not to those two endpoints.

## Refusal and audit

Group: one `address-refused group NAME` row per group per address per hour, written
when a walk meets a refused group the request actually belongs to. The row is written by
SM1139's `Lazysite::Auth::AddressAudit`, the one writer for every refusal by address: one
marker store (`lazysite/auth/.address-refused.db`) and one detail shape (`REASON; lists
NAMES`), origin `web` (the manager API's own refusal says `api`). t/unit/auth/65.

## Tests

- t/integration/285, through the real CGIs behind a trusted proxy (peer 127.0.0.1,
  visitor by X-Forwarded-For): a group allowed from 203.0.113.0/24 grants
  `manage_content` from inside and nothing from outside, as a cookie and as a token
  (with and without a nominated users tool) and over MCP; its `auth_groups` page and
  an `@group` file rule likewise; an operator group limited by address is not
  operator from outside; nesting both ways; deny wins; site-wide `manager_addresses`
  refuses `/manager/` and the API from outside (cookie and token) and not from
  inside, `/login` stays up, deny wins; a faulted store denies a limited group and the
  manager; a `manage_users` holder cannot set a group's addresses and the operator can;
  the audit rows are once an hour; the Config keys.
- t/unit/auth/64: the processor's walk agrees with the module's.

Each fix was put back to its earlier version in turn and the test went red (Settings,
Identity, the manager API, the processor, Common, Config, MCP, and the processor's
copy in t/unit/auth/64).

# Open

- `narrow_caps_to_request` cuts capabilities only; the `dav_scopes` the users tool
  reports for a cookie caller are the account's whole, as before.
