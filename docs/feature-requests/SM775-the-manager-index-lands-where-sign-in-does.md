---
id: SM775
title: "SM775: the manager index lands where sign-in does, and the nav marks what the account cannot reach"
subtitle: "Candidate, from 131E-05 on 0.13.6: a plain manager user opening /manager/ is sent to /manager/config, which renders a heading and nothing else without manage_config and says nothing about why; the left nav offers Users, Groups, Backups and Plugin Manager without the lock markers a sysop session shows. Neither is serious; both read as breakage to the user the start-page feature exists for."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-08 on claude/sm775-the-manager-index-lands-where-sign-in-does. All three: /manager/ forwards to the settings page only for an account holding manage_config and otherwise lands on its own account sheet, where a sign-in with no destination already lands; the settings page names the capability in its BODY when it cannot be read, and no longer asks for what it knows it will be refused; and the nav marks an unreachable item for EVERY account rather than only for one that could grant it. The marker is a registered class, replacing six copies of an inline style. t/unit/manager/160 asserts all three by RENDERING, and each guard was broken to prove the test catches it."
---

# What the field saw

- `/manager/` → `/manager/config`. For `ui-test-2` (`manager_ui`,
  `manage_content`, no `manage_config`) the page is a heading and an
  empty body, with no line saying the account cannot read the site
  configuration.
- The nav for that account lists Users, Groups, Backups and Plugin
  Manager plainly; a sysop's nav marks with a lock the items it cannot
  use. The nav promises more than the account can do.

# What was built

**The index no longer forwards an account to a page it cannot read.** With
`manage_config` it redirects to the settings page exactly as before. Without
it, it stays put and shows the account's own sheet - which is where
`fallback_landing()` already points, so a sign-in with no destination and a
visit to `/manager/` now arrive at the same place rather than both being
forwarded somewhere one of them cannot read.

**The settings page names the capability in its body.** The refusal used to go
to a dismissible warning bar while the body was emptied, so what the account
actually saw was a heading and nothing. It is now a `.mg-note` in the page,
rendered by the server - and the page no longer issues the `config-read` it
already knows will be refused.

**The nav marks an unreachable item for every account.** The marker was on
`ELSIF manager_caps.manage_users`, so only an account that could *grant* the
capability was shown the page it was missing; for everyone else the item
vanished, and a menu that silently differs per account reads as a manager that
has lost a feature. Both now see the item marked. What differs is the sentence:
a user manager is told how to grant it, because they can, and everyone else is
told the account does not hold it - **without being offered a link to a page
they can do nothing with**.

**The marker is a class.** Six lines of the layout carried
`style="opacity:0.55;font-style:italic"` inline. The style guide is the
contract and a hand-styled page is the thing it exists to stop, so
`.mg-nav-locked` and `.mg-nav-lock` are registered in the guide and defined in
all three shipped stylesheets. The marker takes SM686's shape - focusable and
labelled - because a title attribute alone is mouse-only.

# A recorded decision, reversed on the record

`t/unit/processor/47` asserted the old behaviour with its reason written down:
*"Someone who cannot grant it gets nothing: a hint is pointless to a person who
cannot act on it."* That is a real argument and it was made deliberately, so it
is reversed explicitly rather than overwritten.

The field's answer (131E-05) is that the **absence is worse than the pointless
hint**. A menu that silently differs per account does not read as "you may not
have this" - it reads as a manager that has lost a feature, and the person
cannot ask for what they cannot see. The compromise keeps what the old
rationale was protecting: nobody is handed a link to a page they can do nothing
with, because for an account that cannot grant, the marked item is a `<span>`
and not an anchor.

# What was left alone, deliberately

**`%PAGES` was not changed.** Users, Groups, Backups and Plugin Manager carry
`caps => []`, and the field read their plain appearance as the nav promising
too much. They are genuinely openable by any interactive account - the page
renders and shows what that account may see - so marking them would be the
opposite error. What was wrong there is the second bullet, not the third: a
page that shows less should say so, and that is the pattern this establishes
rather than completes.

**The nav is still eighteen hand-written conditionals** duplicating what
`%PAGES` already holds, with `t/lint/116` pinning the two together. Driving it
from the table is the right end state and is a restructure with its own lint
consequences; it is not this filing.
