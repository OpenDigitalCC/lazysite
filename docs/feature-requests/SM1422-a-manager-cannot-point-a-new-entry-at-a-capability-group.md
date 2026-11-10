---
id: SM1422
title: "SM1422: a manager cannot point a new map entry at a capability group"
subtitle: "Ruling 214 (Q129) lets only the operator save an OIDC map entry whose site group carries capabilities. The check kept any entry whose site group the stored map already named, so a manage_config holder could add another provider group beside the operator's entry and give its members the capability. The entry is now kept only as it was saved: the provider group and the site group together."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-10
raised-by: "the lazysite developer agent, proving SM1351 against a local authentik (brief n801, ruling 227)"
area: auth
status-note: "PENDING on claude/n801-oidc-against-a-real-provider: Lazysite::Ext::OIDC::validate_group_map compares entries, not targets. t/unit/manager/743. docs/SECURITY.md."
---

# What happened

Ruling 227 asks for the OpenID Connect sign-in (SM1351) to be proved against a real
provider. Against a local authentik on 127.0.0.1, the operator saved the provider
`test` with the map `staff = staff`, where the site group `staff` carries one
capability. An account holding `manage_config` and not the operator then saved:

- `staff = staff, members = readers`: accepted, as ruling 214 says (a plain group);
- `staff = staff, members = readers, members = sysops`: refused `forbidden`, as it
  says;
- `staff = staff, members = readers, members = staff`: **accepted**.

The next sign-in of a person in the provider's `members` group, and in no `staff`
group, was audited `groups granted: readers,staff`. The manager had given the
capability to every member of a provider group the operator never mapped to it.

# Why

`validate_group_map` kept, for a caller who is not the operator, every site group
that the stored map already named, whatever provider group it came from. Ruling 214
(Q129) is about the entry: "a map entry that targets a capability group can only be
saved by an operator". The docs say the same: a manager "keeps a capability mapping
the operator already made while editing the rest; adding one is refused".

# The change

What is kept is the entry, the provider group and the site group together. A
non-operator may save the operator's capability entries unchanged beside any edit of
the rest, and any plain-group entry; a new entry to a capability group, or the
operator's entry moved to another provider group, is refused `forbidden` with the
words it had, and nothing is written. The operator's saves are unchanged.

t/unit/manager/743 drives it through the manager API; it fails with the old
comparison put back.
