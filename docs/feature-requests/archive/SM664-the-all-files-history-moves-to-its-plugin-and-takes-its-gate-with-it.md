---
title: "SM664: the all-files history belongs on the history plugin's own page, as a modal"
subtitle: "Release manager, 2026-08-28: 'that list should be a modal from the plugin config page, on the history plugin, not on the files page'"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED (PENDING). The overview opens as a modal from the content-history plugin's row and is gone from the Files page; the per-file History panel stays there, being a file operation. THE GATE, as decided: git-history-summary accepts manage_content OR manage_config, in %COOKIE_CAP and in %need. It also had to be added to manage_config's `unlocks` - listing it only under manage_content left the map UNDER-claiming, which no lint catches (they refuse over-claiming and say nothing about omission, which is SM654's point). SIX places for one capability change - %COOKIE_CAP, %need, ControlApi::Actions' registry, manage_config's unlocks, and two generated documents. I accounted for four; t/lint/86 and t/lint/73 found the other two. SM662 says every instance past the second is caught by a gate rather than by reading, and this is that, measured again on the filing that quotes it."
---

# The instruction

The "Content history - all files" overview moves off the Files page. It becomes
a modal opened from the plugin config page, on the content-history plugin's own
entry, where the plugin is enabled and disabled.

# This reverses a decision, deliberately

SM461 asked for exactly this move and was CLOSED BY DECISION on 2026-08-23. The
recorded answer was that the overview stays in Files and no new capability is
created, on the grounds that the surface's readers already hold what it needs,
so the permission question never arises - and that the narrower grant was not
worth the parity cost DP-1 measured for a read-only view.

That decision is now superseded. Recorded here rather than quietly overwritten,
because SM461's own note says a later narrower grant is "a new filing with that
as its whole subject", and this is that filing.

# The half that is cheap, and the half that is a decision

Placement
: The button, the card and `openHistoryOverview()` move from
  `starter/manager/files.md` to the plugin config page, rendered as a modal on
  the content-history row. The per-file History panel STAYS in Files - it is a
  file operation, it belongs beside the file, and SM461 was right about that.

The gate
: `git-history-summary` is gated on `manage_content`
  (`lazysite-manager-api.pl:640` and `:962`). `plugin-enable` and
  `plugin-disable` are gated on `manage_config`. Move the control without
  moving the gate and the plugin config page shows a button that fails for
  exactly the people that page is for - a control the server refuses, which is
  the shape SM662 is about.

# The gate is DECIDED: either capability

Release manager, 2026-08-28: `git-history-summary` unlocks for `manage_content`
OR `manage_config`. The control then works for both the Files audience and the
plugin-config audience, nothing is renamed, and no parity work is incurred.

What it costs is that two capabilities unlock one action, and the capability
map has to say so in every place SM662 counts - `%need`, the action table, the
`unlocks` map and the three generated documents. That is the known price and it
is accepted; SM662 is the filing that makes it cheaper later.

The options as they were put, for the record:

1. Re-gate `git-history-summary` to `manage_config`. The overview follows the
   page it now sits on. Costs nothing new, but says "who may configure plugins
   may read what changed", and manage_config is not obviously the right name
   for a reporting read.
2. Accept EITHER capability. Widest reach, no new name, and the control works
   for both audiences. It does mean two capabilities unlock one action, which
   the capability map has to say in all the places SM662 counts.
3. A narrow read capability, the analytics model - read-only, off by default,
   unlocking one view. This is what the field agent originally asked for and
   what DP-1 priced at nine points of parity work.

Option 2 was taken. Options 1 and 3 are recorded because a later reader will ask
why a reporting read is reachable through a configuration capability, and the
answer is that it is reachable through either.

# Not started

Filed the day 0.11.3 was cut. Nothing is built.
