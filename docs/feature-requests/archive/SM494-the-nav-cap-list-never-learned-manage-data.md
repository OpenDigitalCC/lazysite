---
title: "SM494: the menu could not see a Data grant"
subtitle: "manager_caps is derived from a hand-written capability list, and manage_data was never added to it"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.28 (6ff6499): manage_data joined the nav-gating capability list and t/lint/83 now requires every manager_caps.X the layout references to appear in the derivation, so the next capability cannot be forgotten the same way. Confirmed working by the operator on the deployed edge within the hour. ORIGINAL NOTE: FROM THE FIELD 2026-08-23, on 0.10.27: an operator granted their group Data on the Groups page and the menu still showed 'Data tables' padlocked, linking to Groups - the grant worked, the menu could not see it. The processor resolves qw(manage_config manage_domains manage_users manage_content manage_nav manage_themes manage_layouts audit) into manager_caps and manage_data is absent, so manager_caps.manage_data is false for every non-operator forever. The DM-1 nav test hands manager_caps to the template, so it proves the layout and never the derivation - the tenth parity point, uncounted. FIX: add manage_data to the list; add a lint requiring every manager_caps.X the manager layout references to appear in the processor's derivation list. SIZE S. Direct /manager/data already worked for the granted user - only discovery was broken, which is why it looked like a failed grant."
---

# The finding

Granting a group Data changes what `/manager/data` allows. It changed nothing
in the menu, because the menu's `manager_caps.manage_data` comes from a
hand-written `qw()` list in the processor that predates the capability.

The existing nav tests (`t/unit/processor/28`, `47`) render the layout with a
`manager_caps` hash THEY construct - so the gate logic in the template is
proven, and the derivation that feeds it in production is not touched by any
test. A capability could be added to `@CAP_KEYS`, the groups UI, the layout,
and the guide, and still never reach the menu.

# The fix

- `manage_data` joins the nav-gating list.
- A lint extracts every `manager_caps.<cap>` the manager layout references and
  requires each to appear in the processor's derivation list - the shape that
  makes the NEXT forgotten capability a red test instead of a field report.
