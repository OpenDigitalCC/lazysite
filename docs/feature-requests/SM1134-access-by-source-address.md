---
id: SM1134
title: "SM1134: access limited by the visitor's address"
subtitle: "Named address lists, each allowing or denying, that pages, folders and groups can apply; and a template test, so a page can say what a visitor's address allows."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-17
raised-by: release manager, 2026-10-17
area: auth
status-note: "CANDIDATE, filed and ruled 2026-10-17 (all six as proposed); in build as slices A-D (SM1138-SM1141)."
---

# The request

The release manager, 2026-10-17: "Feature request, to limit access by source
IP. This would be list, with accept block and deny block, and then pages or
groups can have blocks applied. Also some TT could test the blocks."

# What exists to build on

- **The visitor's address** is already worked out in one place,
  `Lazysite::Util::request_address`, which honours `trusted_proxies` (SM929):
  behind a front end it reads `X-Forwarded-For` only from a listed proxy, so a
  visitor cannot name their own address.
- **Address ranges** are already parsed by `parse_trusted_proxies` (IPv4 and
  IPv6 CIDRs), used by `trusted_proxies` and by SM1129's
  `auth_proxy_trusted_from`.
- **The bad-URL guard** (SM128) already refuses a blocked address in the auth
  wrapper, before anything else runs.
- **Per-file access rules** (`acls.json`) and page front matter (`auth:`,
  `auth_groups:`) are where a page or folder already says who may read it.
- **A page that varies by viewer** is kept out of the shared cache (SM1068);
  a page that varies by address needs the same.

# What it would do

- **Address lists**, named, managed on a manager page (Access -> Address
  lists), stored in `lazysite/auth/address-lists.json`, written by the users
  tool like the other access stores, audited on every change:
  - each list has a name, a kind (**allow** or **deny**), entries (single
    addresses and CIDR ranges, IPv4 and IPv6), and a note per entry;
  - a list can be referenced by name wherever a rule can name one.
- **Applied to a page or folder**:
  - front matter `addresses: [office]` (allow) and `addresses_deny: [blocked]`;
  - a per-file access rule (folder or file) gains the same two fields, so a
    whole folder can be limited;
  - a page with an allow list is refused to every address outside it; a deny
    list refuses its addresses; **deny wins** over allow.
- **Applied to a group**: a group can carry an allow or deny list, so its
  members hold the group (and its capabilities and page access) only from
  those addresses. For example, the operator group only from the office, so a
  stolen operator password is no use from elsewhere.
- **Site-wide**: an instance allow or deny list for `/manager/` and the
  manager API, independent of groups.
- **Template test**: `[% visitor.in_list('office') %]` (true or false) and
  `[% visitor.denied %]`, so a page can show "you are on the office network"
  or hide a section. It never exposes the address itself. A page that uses
  it is rendered per visitor and never cached, as a viewer-dependent page is.
- **Refusal**: 403 with the site's refusal page saying the page is not
  available from this address (it does not name the list); one audit row per
  refusal per address per hour, like SM1115, so a scan cannot fill the trail.
- **`lazysite check`** warns when address rules are in use and
  `trusted_proxies` does not cover the front end, because then every visitor
  appears to come from the proxy and the rules mean nothing.

# Rulings

The release manager, 2026-10-17: "1. yes, 2. yes. 3. yes. 4. yes. 5. yes. 6. yes."
Each question below is ruled as proposed: lists in a store managed in the manager;
a group list limits only what the group grants; machine doors included; the
template test exposes membership only; the refusal says "not available from your
address"; lists are shared by the instance and chosen per page or folder.

# Questions for a ruling

1. **Where lists live:** a store managed in the manager (proposed), or lines
   in lazysite.conf?
2. **Groups:** does an address list on a group limit only what the group
   grants (proposed), or sign the member out entirely from other addresses?
3. **Machine doors** (MCP, control API, WebDAV): do group and site-wide address
   rules apply to tokens too (proposed: yes; a token is a member of its
   groups), or only to browser sessions?
4. **Template test exposure:** list membership only (proposed), or the address
   too?
5. **Refusal wording:** say "not available from your address" (proposed), or
   the same refusal as any other access denial, so the rule is not disclosed?
6. **Per domain** on a multi-domain instance: lists shared by the instance
   (proposed), with each page or folder choosing which apply?

# Size

Medium to large: the store and its manager page (M); the check in the
processor's access path, the per-file rules and the group resolution (M); the
template test with its cache rule (S); site-wide manager rule (S); tests
through the real CGIs behind a trusted proxy (M).
