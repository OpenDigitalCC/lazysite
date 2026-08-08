---
title: "SM262 - An agent can create themes but cannot remove them, so it accumulates litter only the operator can clear"
subtitle: "create_theme and install_layout are available over MCP; theme-delete and layout-delete are manager-UI-only. Every experiment an agent runs leaves a permanent artefact."
brand: plain
status: candidate
status-note: "Raised by the site agent 2026-08-08 alongside SM261, and split out because it changes the permission model rather than the documentation. Concrete instance: a zz-guard-theme left behind on edge.explore.lazysite.io that only the operator can clear. The reporter's phrase - create-without-delete makes agents into litter generators - is the whole argument. NOT obviously a bug: the asymmetry may well be deliberate, which is why this is a decision to make rather than a defect to fix."
---

# SM262 - create without delete

## Why

An MCP agent holding `manage_themes` can call `create_theme` and
`install_layout`. It cannot call `theme-delete` or `layout-delete`, which are
served only to the manager UI over a cookie session.

So an agent doing the normal thing - trying a theme, checking it, trying another -
leaves every attempt behind permanently. The reporter left a `zz-guard-theme` on
edge that only the operator can remove. Multiply that by every agent working
every site and the theme list becomes an archaeology of abandoned experiments,
with no one able to tidy it but the person least likely to know which entries
matter.

The asymmetry also undercuts SM234, which this release line spent effort on:
marking a theme "in use by a sub-domain" so the UI does not offer a delete the
server will refuse. That work assumed deletion is a normal operation. For the
agents doing most of the creating, it is not available at all.

## The case for the asymmetry as it stands

Worth stating properly, because it may be the right answer:

- **Deletion is irreversible and creation is not.** A wrong `create_theme` costs
  a list entry; a wrong `theme-delete` costs work that may not exist anywhere
  else.
- **The blast radius is shared.** Themes are instance-wide, so an agent scoped to
  one domain can delete something another domain depends on. SM234's in-use
  check mitigates but does not remove that.
- **A cookie session means a person.** Restricting destructive artefact
  operations to the UI is a deliberate "a human is present" line, and this is one
  of the few places the platform still draws it.

## The case for changing it

- **An agent already has far more destructive powers.** `delete_page`,
  `delete_file` and `move_file` are all available over MCP, all irreversible from
  the caller's point of view, and all mitigated the same way - content history
  keeps the versions. A theme is not more precious than a page.
- **The artefact is one the agent itself created.** The narrow version of this -
  an agent may delete a theme it created, and nothing else - grants no authority
  over anything that existed before it arrived.
- **Litter has a cost too.** An unbounded, un-prunable list is its own kind of
  damage, and it lands on the operator.

## Options, narrowest first

1. **Delete only what you created.** Themes carry provenance already (SM244 reads
   `provenance: lazysite-starter` on pages, so the pattern exists). Stamp the
   creating account on `create_theme` and allow deletion only of matching
   entries. Smallest possible grant; solves the reported case exactly.
2. **A separate capability.** `manage_themes` keeps its current meaning; a new
   grant covers destructive theme operations. Explicit, and one more thing for an
   operator to reason about.
3. **Open `theme-delete` to token clients under `manage_themes`**, relying on
   SM234's in-use check plus the existing refusals. Simplest, largest grant.
4. **Keep it as it is, and say so.** If the UI-only line is deliberate, the fix
   is documentation: state that theme lifecycle ends at the manager, so an agent
   plans accordingly and does not litter by accident.

Option 1 is the one that matches the reported problem without widening authority
over anything else. Option 4 is a legitimate answer and costs almost nothing -
but it should be a decision, not the current silence.

## Verification, whichever is chosen

- An agent can clear an experiment it created.
- An agent cannot remove a theme that predates it, or one another domain uses -
  SM234's in-use refusal still applies and is tested.
- Whatever the rule, `describe_capabilities` states it, so an agent can plan
  rather than discover it (SM261 item 4).

## Scope

`lazysite-mcp.pl`, `lazysite-manager-api.pl`, `Lazysite::Capabilities`, and
whichever briefing describes the theme lifecycle. Related: SM261 (the same
report's documentation items), SM234 (in-use protection), SM195 (grant authority
versus held capability), which is the general form of this question.
