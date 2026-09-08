---
id: SM775
title: "SM775: the manager index lands where sign-in does, and the nav marks what the account cannot reach"
subtitle: "Candidate, from 131E-05 on 0.13.6: a plain manager user opening /manager/ is sent to /manager/config, which renders a heading and nothing else without manage_config and says nothing about why; the left nav offers Users, Groups, Backups and Plugin Manager without the lock markers a sysop session shows. Neither is serious; both read as breakage to the user the start-page feature exists for."
brand: plain
standard-margins: true
status: candidate
---

# What the field saw

- `/manager/` → `/manager/config`. For `ui-test-2` (`manager_ui`,
  `manage_content`, no `manage_config`) the page is a heading and an
  empty body, with no line saying the account cannot read the site
  configuration.
- The nav for that account lists Users, Groups, Backups and Plugin
  Manager plainly; a sysop's nav marks with a lock the items it cannot
  use. The nav promises more than the account can do.

# What would close it

- The manager index redirects to `fallback_landing()` - the account sheet -
  for an account that cannot reach `config`, the same place a sign-in with
  no destination lands (SM724), so the two arrivals agree.
- A page whose reader cannot read it says so in one sentence naming the
  capability, as the start-page refusal does.
- The nav marks every item the account cannot reach, for every account,
  from the same `_page_reachable` the start-page dropdown uses - one
  answer to "what can this account open".
