---
title: "Groups"
brand: plain
---

# Groups

Governing capability: `manage_users`. Capabilities live on groups, never on
accounts - this page is where every grant in the product is actually made.

## Grant a capability

Where
: Access -> Groups -> a group

Do
: Grant `manage_content` to a group, add a user to it, and confirm the user's
  permissions grid on the Users page now shows it.

Expect
: The grid on both pages agrees. The audit trail records the group, the key and
  the actor.

Negative
: A granted channel whose **service** is off is flagged dormant here too, with
  the service named. The Services page shows the reciprocal count.

## Nest one group inside another

Where
: Access -> Groups -> nest

Do
: Nest `junior-editors` inside `editors`, then check a junior member's grid.

Expect
: The junior holds everything `editors` grants, attributed to the granting group.
  Enforcement uses the same closure, so what the grid shows is what applies.

Negative
: A direct self-loop is refused. A longer cycle is harmless - the resolver
  terminates on it - but nesting a group into itself is a mistake worth catching.

## Grant authority (who may confer what)

Where
: Access -> Groups -> a group's grantable set

Do
: As an operator, give a group authority to grant `manage_content`. Then, as a
  delegate in that group, try to grant `manage_content` and then `manage_users`.

Expect
: The delegate can confer `manage_content` without holding it, and is refused
  `manage_users`.

Negative
: **A delegate must not be able to set grant authority itself.** Try it: the
  refusal should say that grant authority is conferred from above and never
  self-assumed. A delegate who could widen its own grantable set would have no
  ceiling at all.

## Confinement is not set here

Intentionally omitted: a group `dav_scope`. It was retired in 0.7.26 and the
tooling now refuses it. Confinement lives on the **domain** - configure the domain
with its own content root and name the group in its `allowed_groups`. See
Domains.
