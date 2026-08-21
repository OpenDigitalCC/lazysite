---
title: "SM467: a setup-manager admin cannot grant API or MCP access, and the refusal does not say how"
subtitle: "setup-manager seeds the admin group with every capability except api and mcp, and no grant authority. So the only account on a fresh site cannot add anyone to a group that grants either - including the AI-agent group the documentation tells them to use."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED (PENDING). RESOLVED IN THE DIRECTION THE OPERATOR EXPECTED, and the two halves turned out not to conflict: SM127 bounds what a manager may USE, `grantable` governs what it may CONFER, and caps_for() never reads grantable - _may_confer is its only consumer - so a manager group can now hand out api/mcp while still being unable to use either. Manager groups are seeded with grantable => [api, mcp] at all three seeding sites. The refusal in cmd_group_add, cmd_token and cmd_claim_create now names the remedy, matching the message cmd_group_settings_set has carried since SM195. NOT DONE, deliberately: existing installs are not repaired, because seeding grant authority into a deployed site would silently widen it; the refusal now tells the operator what to run. ORIGINAL FILING FOLLOWS. FILED 2026-08-21 from the field, on a new site. REPRODUCED on a scratch install, not read off the source: setup-manager, create a group granting api, add a user to it as the manager -> 'You cannot add anyone to agent-ai: it grants api, which you may not confer.' THE CAUSE, at tools/lazysite-users.pl:974: _ensure_manager_group_caps seeds the admin group with every capability EXCEPT api and mcp, and seeds no grantable set. _may_confer then allows a non-operator to confer a capability only if they HOLD it or it is in a group's grantable list, so the bootstrap admin can never confer either channel. THE PART THAT MAKES IT A TRAP RATHER THAN A POLICY: grantable is operator-only to set, deliberately and correctly - a delegate that could widen its own grant authority would have no ceiling at all. So the one account on a fresh site cannot fix this from the UI, and the refusal names the capability but not the remedy, so there is nothing to act on. VERIFIED REMEDY, also on the scratch install: `group-set lazysite-admins grantable api,mcp` from the CLI, after which the same group-add succeeds. That is the SM195 mechanism working as designed - authority to CONFER, conferred from above, without the admin holding the channel capability itself. THE DECISION IS WHETHER THE SEED SHOULD INCLUDE IT, and it is the release manager's: seeding grantable => [api, mcp] on the manager group would let a fresh site set up an AI agent without shell access, and the argument for is that this group already holds manage_users and every other capability, so it is the operator in all but name. The argument against is that api and mcp were excluded from the seed on purpose and this partially reverses that. SEPARATELY AND REGARDLESS OF THAT DECISION: the refusal should say what to do. It is a correct refusal that leaves the operator with no path, which is the same shape as SM446 and SM461 - a control that reports accurately and strands the person reading it."
---

# What happens on a fresh site

```datatable
columns: Step | Result
widths: 8cm | X
bold: 1
tone: medium
---
`setup-manager` | admin group holds everything except `api` and `mcp`
Manager adds a user to a group granting `api` | refused: *which you may not confer*
Manager sets that group's grant authority | refused: operator-only
```

Each refusal is correct on its own. Together they close the loop: the only
account that exists cannot perform the action, and cannot grant itself the
authority to perform it, and is not told what would.

# Why the ceiling is right and the seed is the question

`grantable` being operator-only is what makes the whole mechanism safe -- a
delegate able to widen its own grant authority has no ceiling at all, and the
first thing an attacker holding `manage_users` would do is exactly that. That
is not the part to change.

The question is only whether a *bootstrap* admin -- which holds `manage_users`
and every other capability, and is the operator in all but name -- should be
seeded with the authority to confer the two channel capabilities it
deliberately does not hold.

# The refusal, either way

Whatever is decided about the seed, the message is a separate defect. It names
`api` accurately and stops there, and the person reading it has no way to know
that `grantable` exists, that it is the mechanism for this, or that it is set
from the CLI.
