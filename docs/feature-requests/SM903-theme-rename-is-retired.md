---
id: SM903
title: "SM903: `theme-rename` is retired - the one way to change a theme is copy, edit, activate"
subtitle: "SM749 made the served theme read-only and put Copy on Appearance in Rename's place. The control-API action outlived the button by four minor versions, reachable only by a caller who read the actions list, and could rename a non-active theme in place. The release manager ruled on 2026-09-26: retire it."
brand: plain
standard-margins: true
status: shipped
raised: 2026-09-26
raised-by: engine agent, from SM902's register question
area: themes
status-note: "SHIPPED - the ruling of 2026-09-26. Removed: the `theme-rename` entry in Lazysite::ControlApi::Actions, its dispatch and its three list entries in lazysite-manager-api.pl (the cookie-only list, the mutating list, the capability map), and Manager::Themes::action_theme_rename with its export; the generated control-api-actions.md no longer carries the row. Tests: t/unit/manager/102 (the SM532 guards on RENAME - the active theme and a domain's theme could not be renamed out from under the site) is gone with its subject, and those guards live on in delete, which t/unit/manager/… already holds; the rename subtest of t/unit/manager/187 (a name is refused, not rewritten) is gone the same way and the copy subtests it sat beside are the ones that matter now; the write-guard registry (t/lint/15), the audit registry (t/unit/lib/16) and the git-guarantee registry (t/unit/lib/18) drop the entry. _rename_theme_creator, which only the rename called, is gone too. WHY RETIRE RATHER THAN KEEP: two ways to change a theme is the shape SM749 removed on the page; an in-place rename reachable only from the API is the second way coming back where nobody looks, and a rename of a theme a domain uses would have left that domain naming a directory that no longer exists (the guard SM532 added is exactly the guard delete needs, and delete has it). Nothing in the tree, the manager or the skill called it."
---

# The ruling

SM902's register row asked whether `theme-rename` stays. The release manager
ruled 2026-09-26: **retire it**. This filing is the record of the removal.

# What went

| Where | What |
| --- | --- |
| `lib/Lazysite/ControlApi/Actions.pm` | the `theme-rename` entry |
| `lazysite-manager-api.pl` | the dispatch branch, the import, and the entries in the cookie-only list, the mutating list and the capability map |
| `lib/Lazysite/Manager/Themes.pm` | `action_theme_rename` and `_rename_theme_creator`, which only it called |
| `docs/reference/control-api-actions.md` | the row (generated from the actions table) |
| `t/unit/manager/102` | removed - its subject was the rename's guards |
| `t/unit/manager/187` | the rename subtest; the copy subtests stay |
| `t/lint/15`, `t/unit/lib/16`, `t/unit/lib/18` | the registry entries |

# What stays

- **Copy** on Appearance and `theme-copy` on the control API - the first step
  of the one way to change a theme (SM749).
- The SM532 guards - the active theme and a theme a domain resolves to cannot
  be removed out from under the site - on **delete**, where they were also
  built.

# Related

[[SM749]] (the served theme is read-only; Copy), [[SM532]] (the guards),
[[SM902]] (the question), [[SM861]] (a theme name is refused, not rewritten).
