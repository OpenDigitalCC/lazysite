---
id: SM1189
title: "SM1189: an address rule is checked for the form and the kind it needs"
subtitle: "A bare addresses value says the address sentence instead of sign in, and a list of the wrong kind is refused, named and no longer ignored."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-19
raised-by: inbox/2026-10-19-test-plan-01510-results.md, findings F-2 and F-3
area: auth
status-note: "SHIPPED on n678: Lazysite::Validate, Lazysite::Auth::AddressLists::decide, lazysite-processor/auth.pm, Manager::Files acl-set, lazysite-users group-set, lazysite-check; t/unit/lib/205, t/integration/144, t/integration/145, t/unit/tools/85."
---

# What happened

The edge walk of 0.15.10 (Y2) found two faults in how a page's address rule is
read:

> F-2, a bare `addresses:` value gives the wrong refusal. `addresses:
> zz60-mine` (not a YAML list) refuses the page to everyone with "You need to
> sign in to view this page", including a signed-in member. It is the
> `auth_groups` rule ("a value that is not a list refuses the page to
> everyone"), but the sentence sends a reader to sign in, which cannot help. The
> validator or the refusal should name the front matter.

> F-3, an allow list in `addresses_deny` is silently ignored.
> `addresses_deny: [zz60-mine]`, where zz60-mine is an allow-kind list holding
> the visitor's address, leaves the page open. A deny-kind list with the same
> address refuses it. So naming a list of the wrong kind does nothing, and says
> nothing. Refuse it at save or in the validator, or have `lazysite check` name
> it.

The validator already refused a bare value (SM980, SM1094) but its example did
not say the value must be written as a list. A deny-slot name of the wrong kind
was skipped by `decide` (SM1138), so the rule failed open; an allow-slot name of
the wrong kind failed closed only because nothing else admitted the visitor.

# What shipped

F-2.

- The validator's message for a value that is not a list now reads "write it as
  a list: addresses: [office], or one "- office" line per list below it", for
  `addresses`, `addresses_deny` and `auth_groups` alike (the same reader; the
  processor's marked copy says the same, lint 220).
- The refusal a visitor sees for an address rule the engine cannot read is the
  SM1139 sentence, "This page is not available from your address.", the one
  every other refusal by address says. The choice follows how SM1139 words its
  refusals: one ruled sentence, naming no list and no key, which sends nobody to
  a sign-in that cannot help. The author is told by the validator and
  `lazysite check`; the visitor is not told what the rule says. A page whose
  unreadable keys include `auth`, `auth_groups` or `payment` keeps its existing
  refusal. Both stay refused to everyone (fail closed).

F-3.

- `Lazysite::Validate` (`validate_page`, `lazysite validate`, the MCP tool) reports
  `address-list-wrong-kind` for a page naming a list of the other kind, naming the
  key, the list and its kind. A name the store does not hold is not reported (a list
  may be created later).
- Saves refuse it and write nothing: `acl-set` (manager API and MCP) used to accept
  it with a warning; the Groups `addresses` / `addresses_deny` setting
  (`group-set`) now checks the kind as the Config page already did for
  `manager_addresses`, `signin_addresses` and their `_deny` keys. A page's front
  matter is not saved through a gate that runs the validator, so that place is
  named by the validator and the check.
- `lazysite check` warns for every existing rule of the wrong kind, in page front
  matter, acls.json, group records and the four lazysite.conf keys, naming the list
  and the place.
- At request time `decide` now answers `deny, wrong-kind` for a name of the wrong
  kind in either slot, rather than skipping it. The old answer was fail closed in
  the allow slot and fail open in the deny slot; one rule that is the same in both
  slots and in every user of `decide` (pages, folders, groups, sign-in, the
  manager) is the SM980 rule: a restriction the engine cannot apply refuses. The
  audit row's reason is `wrong-kind`.

Left open: a bare `auth_groups` still refuses with the sign-in sentence; that
refusal is not an address one and was not part of the finding.
