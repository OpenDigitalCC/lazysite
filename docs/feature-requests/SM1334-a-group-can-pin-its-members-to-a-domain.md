---
id: SM1334
title: "SM1334: a group can pin its members to a domain"
subtitle: "Ruling 78: only pinning removes the other domains - home_domain, for an account or a group. An account could be pinned (a domain's locked_users); a group could not. A domain's locked_groups now pins every member of the groups it names, and a pin on the primary confines to the primary."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-05
raised-by: "ruling 78 (Q10, triage T-40): \"only pinning (home_domain, for an account or a group) removes the others\"; the owner: \"maybe this is a group, not a user\""
area: security
status-note: "SHIPPED (PENDING) on n746: locked_groups on a domain and on the primary row (DomainAccess, the processor's copy, domain-set, domain_access_edit, the Domains sheet, MCP domain_set, lazysite-domains pin-add/pin-remove); a pin on the primary confines there; the request's scopes are held inside the account's whole. t/unit/lib/211, t/unit/manager/426, t/unit/processor/175."
---

# Could a group carry a pin?

No. The ruling names the pin as `home_domain`. That stopped being a setting in
0.7.26: `lazysite-users set U home_domain` is refused ("access lives on the
DOMAIN"), and `home_domain` in whoami is derived, the one domain an account is
rooted at. The account's pin is a domain's `locked_users` (SM165): an account
named there reaches only the domains that lock it, of the ones its groups are
granted. Groups had no equivalent: `groups-settings.json` holds capabilities,
address limits and the operator flag, and no domain key named a group's lock.

# What shipped

- **`locked_groups` on a domain** (`alias.<host>.locked_groups:`) and on the
  primary's row (the bare `locked_groups:` line): a comma list of groups. Every
  member of a group named there is locked to that domain, exactly as an account
  named in `locked_users` is: it reaches only the domains that lock it (by name
  or by group), of the ones it is granted, and nothing if none of those is
  granted (deny-all, never unbound).
- **On the domain, not the group**, as every access key is (SM165: access lives
  on the domain). It is written and refused like `allowed_groups`: `@name` or
  `name`, stored as the name, a group the site does not have refused (SM1016),
  `manage_users` needed as well as `manage_domains` (SM647) on the control API
  and MCP.
- **A pin on the primary confines to the primary.** Pinned there (by account or
  by group), an account's scope is the primary's (`/`). Before, a lock whose
  domains all served the docroot left the scope list empty, unbound - which a
  signed-in manager reads as every domain - and no pin on the primary could be
  written until SM1332 gave it a row, so nothing changes at upgrade.
- **Losing a group cannot lift its pin.** SM1140 resolves a request's scopes from
  the groups the request's address allows, and claimed the result always lies
  within the account's whole ("fewer groups reach fewer domains; a lock is the
  account's own"). A group's lock breaks that: leaving the pinning group out
  would leave the other grants unpinned. The request's scopes are now cut to the
  whole (`intersect_scopes`), so they are never wider.
- **Surfaces**: `domain-set` and `domain_access_edit` (key `locked_groups`, any
  host and `(default)`); `lazysite-domains.pl pin-add --host H --group G` and
  `pin-remove`; the Domains sheet's **Groups locked to this domain**, on every
  row and on the primary's; MCP `domain_set`'s key list; both listings.
- **The processor's copy** (the file browser's rooting) reads the same key.

# Tests

- t/unit/lib/211: the key is read on a domain and on the primary; a group pin
  narrows to the pinned domain; a pin on an ungranted domain is deny-all; the
  account and group pins are one lock; a pin on the primary confines there; a
  group left out of the request's walk cannot lift its pin.
- t/unit/manager/426: `locked_groups` through `domain-set` (stored plain,
  listed, on the primary row, unknown names refused, `manage_users` needed).
- t/unit/manager/427: the primary's sheet holds the group lock.
- t/unit/processor/175: the processor's copy agrees on the group pins.
- t/unit/lib/210: a pin on a primary that names nobody now confines there.
