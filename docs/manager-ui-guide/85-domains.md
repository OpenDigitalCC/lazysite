---
title: "Domains"
brand: plain
---

# Domains

Governing capability: `manage_domains`, carved out of `manage_config` precisely
so it can be delegated separately.

## Add a domain

Where
: System -> Domains -> Add domain

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
: System -> Domains -> Configure

Do
: Open the sheet for a domain you just added.

Expect
: The sheet shows what you set. Both modes - add and configure - agree about
  which fields a domain has; there is one form, not two that drift.

Negative
: A scope-confined manager sees only the domains they may manage.

## Preview, check, export and delete

Where
: System -> Domains -> a domain's controls

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
: System -> Domains -> a domain -> allowed groups / locked users

Do
: Name a group in a domain's `allowed_groups`, add a user to that group, and sign
  in as them.

Expect
: **This is where confinement is set.** The user's scope becomes the content
  roots of the domains their groups may manage, intersected up the `created_by`
  chain so a sub-user can never out-reach its creator. It applies on the manager,
  WebDAV, MCP and the control API alike.

Negative
: A locked user with no allowed domain is denied everywhere - never silently
  unconfined. That sentinel is the whole safety of the model: confirm it by
  locking a user to a domain and then removing their group from it.
