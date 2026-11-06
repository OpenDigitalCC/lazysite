---
id: SM1370
title: "SM1370: a token follows its account's grant"
subtitle: "Ruling 121: a token's capabilities follow its account's current grant at each request, so a grant change takes effect without re-pairing, and a grant removed at the account is removed from every token at once. Measured: every token door already resolves the account afresh. Tests now hold that on each door, and both whoamis say it."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-06
raised-by: "release manager, ruling 121 (0.16.6 brief n758)"
area: auth
status-note: "SHIPPED on n758: the three behaviours already held on every token door and are pinned by t/unit/manager/460; both whoamis carry a `grant` block (Capabilities::whoami_roles)."
---

# What was asked

Ruling 121: a token's capabilities follow its account's current grant at each
request. A grant change takes effect without re-pairing; a grant removed at the
account is removed from every token at once. What already caps a token still
holds: a token never exceeds its account, and a token minted narrower stays
narrower.

# What was found

Nothing on the pairing exchange, the token mint or the OAuth store fixes a
capability into a credential. Read from the source, then measured with the real
users tool and stores (t/unit/manager/460, subtests 1 to 3, pass on the base
commit b7f178856 unchanged):

- **The pairing exchange** (`cmd_token_exchange`, `tools/lazysite-users.pl`)
  replaces the account's credential hash and sets its expiry. It records no
  capability.
- **An lzs_ token** on the control API and MCP verifies through
  `Lazysite::Auth::Verify::verify_credential`, which builds the account's
  settings from `caps_for` - the group store, read at that request. The manager
  API rebuilds `%token_caps` per request; MCP's `verify_bearer` per call.
- **An OAuth access token** (`Lazysite::Auth::OAuth`) maps to a partner and
  nothing else; MCP resolves that partner's capabilities through `partner-caps`
  at each call. A refresh mints a new access token for the partner and no
  capability.
- **WebDAV** asks `caps_for` once per process, and the endpoint is a plain CGI,
  so once per request.

So a grant added at the account reaches an existing token on its next request, a
grant removed is refused on its next request, on every door, and a token's
domain scope still confines it when the account widens. The connector docs
already said so ("a grant is effective immediately - you do not need a new
token"). What an agent sees as "my grant did not arrive" is its client's tool
list: an MCP client lists tools when it connects, and this server declares
`listChanged: false` and has no channel to push a change, so a new tool appears
after the client lists again.

There is no token minted narrower than its account in this release: a token is
the account's one credential, or an OAuth grant to the account. What narrows a
token's request today is its domain scope and its address (SM1140), both
resolved per request from the account's groups; the test holds the scope case.

# Change

- **The behaviour is pinned on each door.** t/unit/manager/460 mints a token
  before a grant and checks the control API (`form-list`), MCP over an lzs_
  bearer and MCP over an OAuth token: refused before `read_submissions`,
  admitted after it with no new key, refused at once after it is taken away;
  and a token confined to one domain is still refused another domain's page,
  read and write, after the account gains four more capabilities. A cache or a
  snapshot added later fails here.
- **Both whoamis say where the grant comes from.** A `grant` block,
  `{ source: "account", note }`, from one builder
  (`Lazysite::Capabilities::whoami_roles`, shared with SM1371's `roles` block):
  capabilities are resolved from the account's groups at each request, a change
  applies from the next request with no new pairing key, and a missing tool means
  the client's list predates the grant.
- **The docs say the same.** The connector tools reference adds the removal and
  the scope case and the tool-list note; the layouts briefing's "rotating your
  token is a reliable belt-and-braces" becomes "call whoami; list the tools
  again", since rotating changes nothing about a grant.

# Choices made

- **No token-level capability set is added.** "A token minted narrower stays
  narrower" has no case in this release to preserve beyond the domain scope and
  the address rule, which are held. Adding a per-token narrowing would be a
  second place a capability is decided, outside the groups-only model of ADR
  0003; it is left for a ruling if wanted.
- **`listChanged` stays false.** Declaring it true without a way to send the
  notification would promise a change notice the server cannot deliver. The
  whoami note and the docs carry the remedy instead.

# Tests

t/unit/manager/460-a-token-follows-its-accounts-grant.t. Subtests 1-3 pin
behaviour that already held (they pass on the base commit, which is the
finding); subtest 4, the `grant` and `roles` blocks on both whoamis, fails with
the change reverted.
