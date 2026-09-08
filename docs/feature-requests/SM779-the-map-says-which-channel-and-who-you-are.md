---
id: SM779
title: "SM779: the capability map says which channel serves an action, and who you are"
subtitle: "Reported from familyhq.explore (0.12.1): 'Action not available to token clients: users ... call describe-capabilities' sent the caller to a document that listed users beside data-rows with nothing to tell them apart (141 actions there, 65 callable), and whose holds block named the account by login only."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-08 on claude/sm779-the-map-says-which-channel-and-who-you-are. describe-capabilities' actions map marks every cookie-only action (cookie_only: true - the fact actions-list already publishes); holds carries display_name beside account on both the control API and MCP; the cookie-only refusal points at actions-list, the document that models the channel. t/unit/manager/10 and t/unit/mcp/02 assert all three."
---

# What the field saw

- `describe-capabilities.actions` carried `mutating`, `destructive`,
  `changes_access` for every registered action - 141 of them, when
  `actions-list` returned the 65 this channel serves. `users` and
  `data-rows` were indistinguishable.
- The cookie-only refusal ended "Call describe-capabilities to see what this
  account can do over the API" - the document that could not answer it.
- `holds.account` was a login with no display name anywhere in the response.

# What is built

- `actions.<name>.cookie_only: true` for every action the control API
  declares without capabilities (the cookie channel's), from the same table
  `actions-list` reads.
- `holds.display_name` beside `holds.account`, on the control API and on
  MCP's `describe_capabilities`, read from the account store.
- The refusal: "Call actions-list to see what this account can call over
  this channel."

# Filed with it

The larger request - one register of people, including people who cannot
sign in; the display name wherever a login is handed back; a read-only name
lookup for a page - is SM778, with the operator's ruling recorded.
