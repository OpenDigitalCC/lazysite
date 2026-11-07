---
id: SM1404
title: "SM1404: a listing carries no entry named after a rule's address profile"
subtitle: "Triage T-93, reproduced: list_files over MCP answered with the permissions editor's profile choices beside the entries, a list of { name } that read as an entry named after the folder rule's address profile, with no type. The choices now ride on the manager API's listing only."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "0.16.7 edge triage, T-93 (reproduce before anything)"
area: manager
status-note: "SHIPPED (PENDING) on n771: Manager::Files::action_list returns `address_profiles` only when asked (pickers => 1); the manager API's list branch asks, MCP list_files does not; acl-get is unchanged. t/unit/manager/477."
---

# What happened

On 0.16.6 an operator's `list_files /zz78-addr` listed an entry named after the
folder rule's address profile (`zz78-allow`), with no type, beside the page.
`Manager::Files::action_list` builds entries from `readdir` of the docroot
folder and its private-store sibling only, so the triage asked for a
reproduction before any fix.

# Reproduced

On a scratch site (tmp/n771-t93-probe.pl): a page under `/zz78-addr`, a profile
`zz78-allow`, a folder rule `zz78-addr` naming it in `addresses`, then
`action_list('/zz78-addr')`. The `entries` list held the page alone, with
`governed_by: zz78-addr`. Beside it the answer carried

    "address_profiles": [ { "name": "zz78-allow" } ]

SM1139 added that list for the Files page's permissions editor (its pickers)
and `action_list` returned it on every listing answer, whatever door asked.
Over MCP, `list_files` is that answer verbatim, and a reader working down the
JSON met a row with a `name` and no `type` next to the page - an entry named
after the rule's address profile. That is what wrote it: not `readdir`, not a
file on disk (nothing named `zz78-allow` exists under the docroot), but the
picker choices riding on the wrong door.

# What was built

- `action_list( $path, pickers => 1 )` carries `address_profiles`; without
  `pickers` it does not. The manager API's `list` branch asks for them (the
  Files page sets its `ADDRESS_PROFILES` from the listing); MCP `list_files`
  asks without, as does any other caller.
- `acl-get` still carries the choices, per rule, as SM1139 made it.

Test: `t/unit/manager/477` - the bare listing holds the page and nothing named
after the profile (the name is nowhere in the answer), the manager's listing
holds the choices, the API passes `pickers` and the MCP tool does not. Fails
with the listing and the API reverted.
