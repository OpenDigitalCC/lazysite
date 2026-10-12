---
title: "Domains"
brand: plain
---

# Domains

Governing capability: `manage_domains`, carved out of `manage_config` precisely
so it can be delegated separately.

## Add a domain

Where
: Setup -> Domains -> Add domain

Do
: Add one three ways: with a content folder, title, appearance and seed ticked;
  with only the host filled in; and using **Copy settings from** an existing
  domain.

Expect
: The first registers with a seeded home page. The second registers with
  everything else shown as inherited. The copy brings across the content folder,
  title, appearance and language - and **not** the site address, which the new
  host gets for itself.

Negative
: Type a host and watch the site address fill itself in; then edit the address by
  hand and keep typing in the host. The address must stop following once you have
  touched it.

## Configure a domain

Where
: Setup -> Domains -> Configure

Do
: Open the sheet for a domain you just added.

Expect
: The sheet shows what you set. Both modes - add and configure - agree about
  which fields a domain has; there is one form, not two that drift.

Negative
: A scope-confined manager sees only the domains they may manage.

## Preview, check, export and delete

Where
: Setup -> Domains -> a domain's controls

Do
: **Preview** a domain with no DNS pointed at it. **Check** it. **Export site**.
  Then **Delete**.

Expect
: Preview renders server-side under the domain's own Host, so it works before DNS
  exists - that is its purpose. Check probes DNS, TLS and the vhost, and refuses
  to probe a host that resolves to a private address. Export produces a portable
  site package with a `.sha256` sidecar beside it.

Negative
: Delete is the only destructive control in the danger zone, and it confirms with
  what will be lost.

## Access, and therefore confinement

Where
: Setup -> Domains -> a domain -> allowed groups / locked users

Do
: Add a group to a domain's **Groups allowed to manage** (the picker offers each
  group as `@name`), press Save, add a user to that group, and sign in as them.

Expect
: **This is where confinement is set.** The user's scope becomes the content
  roots of the domains their groups may manage, intersected up the `created_by`
  chain so a sub-user can never out-reach its creator. It applies on the manager,
  WebDAV, MCP and the control API alike.

  Before Save, adding or removing a group or user marks the field changed and
  the sheet counts it; Save then says **Saved**, and the domain lists the
  group. Saving with nothing changed says "Nothing had changed."

  `allowed_groups` stores the group's plain name; a group may be given as
  `@name` or `name` anywhere it is written (this sheet, the MCP `domain_set`
  tool, the control API's `domain-set`, `lazysite-domains.pl`).

  From a shell, `lazysite-domains.pl --docroot DIR group-add --host H --group G`
  adds one group and keeps the others (`group-remove` takes one out;
  `user-add` and `user-remove` do the same for locked users). It refuses a
  group or account the site does not have, naming it, and says when there was
  nothing to do.

  Every surface refuses a group or account the site does not have (SM1016):
  the sheet shows the refusal, naming each unknown name, and nothing is saved.
  A name the list already holds is not checked, so a group deleted since it
  was allowed can still be removed.

Negative
: A locked user with no allowed domain is denied everywhere - never silently
  unconfined. That sentinel is the whole safety of the model: confirm it by
  locking a user to a domain and then removing their group from it. A TOKEN
  whose group no domain names writes no domain at all (domain-add, -set,
  -remove, remap-save, site-backup-apply); only the operator's own session
  reaches every domain without a scope (SM975).
