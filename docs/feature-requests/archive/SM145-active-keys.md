---
title: "SM145 - Active keys on the Sessions page"
subtitle: "See and revoke machine access keys (AI / API / WebDAV)"
brand: plain
status: shipped
status-note: "delivered 2026-07-12; keys-list / key-revoke (users tool + manager-api, manage_users-gated), Sessions-page Active keys table with per-key revoke; interactive accounts excluded (their credential is a login password)"
---

# SM145 - Active keys on the Sessions page

## Why

Operators could see and revoke browser **sessions**, but not the **access keys**
that let AI agents and publishing tools reach the site without a browser (the
API, the MCP connector, WebDAV). Following the SM144 account work, an operator
should be able to see active machine keys and revoke one in the same place.

## Shape

- An **Active keys** card on `/manager/sessions`, listing each account that
  holds a live machine credential: the channels it carries (api / mcp / webdav),
  when it was issued, whether it has been used since issue, and any expiry.
- **Revoke key** per row: clears the credential so it stops authenticating on
  the next request; the account is untouched and can be re-issued a key from its
  Users-page card.

## Boundaries

- A "key" is a credential on a **non-interactive** account. An interactive
  (human) account's credential is its **login password** - even if it also has
  WebDAV - so those accounts are excluded from the list, and `key-revoke`
  refuses them (revoking would be a lockout, not a key revocation; manage the
  password on the Users page).
- Same gate as sessions: cookie callers need **manage_users**; token clients
  cannot reach `keys-list` / `key-revoke` at all.

## Implementation

`cmd_keys_list` / `cmd_key_revoke` in `tools/lazysite-users.pl` (the credential
store owner); native `keys-list` / `key-revoke` actions in
`lazysite-manager-api.pl` gated with sessions and forwarded to the users tool;
`starter/manager/sessions.md` renders the card. `key-revoke` is audited
(`user-key-revoke`); `keys-list` is a read. Tests: `t/unit/users/17-keys.t`;
classification pinned in `t/unit/lib/16-audit-guarantee.t`.
