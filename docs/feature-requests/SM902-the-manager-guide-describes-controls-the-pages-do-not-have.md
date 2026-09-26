---
id: SM902
title: "SM902: the manager guide describes controls the pages do not have - twelve sentences across its thirteen pages"
subtitle: "The sites agent's X6 walk of `starter/docs/manager.md` against a live 0.14.4 manager, every page plus the Admin bar, Installation and Security sections. Twelve sentences describe something the page does not do. One names a control that has not existed since SM749 - a per-theme Rename - while the control API still carries `theme-rename`."
brand: plain
standard-margins: true
status: shipped
raised: 2026-09-23
raised-by: sites agent, from the X6 walk on edge 0.14.4
area: documentation
status-note: "SHIPPED - the seven sentences now say what the pages do, each checked against the page source before it was rewritten. (1) Site settings: the active layout and theme are NOT shown there - the sentence promised them read-only with a link; the page carries none. (2) Site settings also carries backups to keep, the asset cache lifetime, the five service switches with their holder lines, pairing-key exchange and token rotation, the manager style and the update channel - the guide named none. (3) Content history: `enable` and `disable` are hidden actions (plugin-config.md says why); the tick on Extension Manager is the control, so the guide no longer promises Enable / Pause buttons. (4) The editor's preview refreshes on Save and on Reload preview (edit.md:136, 877), not as you type. (5) The front-matter form shows the page's own keys; `date` only when the page has one. (6) Nav: labels and URLs are edited in a dialog, and a blank URL makes a heading - there is no inline edit and no toggle. (7) Appearance: the switcher is the Installed layouts & themes card; `layouts_ref` is a lazysite.conf key with no control on the page; and the per-theme controls are Preview, Activate, Delete and COPY - Rename went with SM749, which made the served theme read-only. ONE QUESTION for the release manager, in the decision register: `theme-rename` is still a control-API action with no page behind it since SM749. Retire it, or keep it as a typed-surface convenience? Not decided here. CHUNKS 6-13, the same morning: three more sentences - the Users list has no identity banner and no Configure button (one line per account, Edit, the identity in the sheet's head), Add group takes a name alone and a group deletes only once empty, and the full-system restore line carries --domain as the page prints it. Twelve lines in all; the walk is closed and recorded in the manual-check register. RULED 2026-09-26: theme-rename is retired - SM903 carries the removal, and the register row is gone."
---

# What was measured

`starter/docs/manager.md` from the 0.14.4 tarball, walked page by page on
edge as a signed-in manager, reading the manager's own DOM. Most sentences
PASS. These did not:

| Page | The guide said | The page does |
| --- | --- | --- |
| Site settings | the active layout and theme are shown read-only with a link to Appearance | nothing about layout or theme; the only route to Appearance is the sidebar |
| Site settings | (nothing) | backups to keep, asset cache lifetime, five service switches with holder counts, pairing-key exchange and token rotation, manager style, update channel |
| Extension Config | Content history offers Enable / Pause recording for recovery | Status and History overview; `enable`/`disable` are hidden actions, and the tick on Extension Manager is the control |
| Editor | "Live preview pane" | refreshed on Save and on Reload preview (`edit.md` lines 136 and 877) |
| Editor | front matter form: title, subtitle, date | title, subtitle, and the page's own keys; `date` only where the page has one |
| Nav | edit labels and URLs inline; toggle between links and headings | a dialog per row; a blank URL makes a heading |
| Appearance | "Active layout & theme" card; `layouts_ref` beside `layouts_repo`; per-theme rename | the card is "Installed layouts & themes"; `layouts_ref` is a conf key with no control; per theme Preview / Activate / Delete / Copy - no Rename since SM749 |
| Users | an identity banner on selecting a row; a Configure <name> button; a coloured sheet head | one line per account with a kind tag, `(+N)`, flags and **Edit**; the identity is the sheet's own subtitle; the head is plain |
| Groups | creating a group needs a first member | Add group takes a name alone; deletion is offered only once the group is empty |
| Backups | `--restore-full FILE` | the page prints `--restore-full FILE --domain NEW-DOMAIN` |

# The one that is not a sentence

`theme-rename` is still declared in `Lazysite::ControlApi::Actions` (caps
`manage_themes`, `path` + `new_name`) and dispatched in the API. No page
calls it: SM749 made the served theme read-only and made **Copy** "the first
step of the only way to change it (copy, edit, activate)". A typed caller
can still rename a non-active theme. Whether that survives is the release
manager's - a question in the decision register, not a change here.

# What is NOT claimed

- Any control missing that the design intends. Rename was retired on
  purpose; the guide had not caught up.
- The Security section: the agent's probe was refused by its own policy gate
  and it did not go round it. The suite carries that ground
  (`t/unit/manager/61-security-review-regressions.t`).

# Related

[[SM749]] (the served theme is read-only; Copy), [[SM635]] (the retired
protected-sections card - the same shape, caught by the same walk),
[[SM254]] and [[SM263]] (engine docs drift, the earlier sweeps).
