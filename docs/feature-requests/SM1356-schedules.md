---
id: SM1356
title: "SM1356: schedules: weekly hours, exceptions and dated items"
subtitle: "Opening hours set once through a wizard, holidays and closures added as exceptions, and items that show until a date and then hide themselves."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-06
raised-by: "release manager (SM1350 discussion)"
area: data
status-note: "Filed 2026-11-06 under SM1350."
---

# Proposed

- **A schedule:** weekly opening periods (several a day allowed) plus exceptions (a date or date range: closed, or different hours) in the site's time zone. Set through a wizard (SM1355).
- **Rendering:** blocks for the week's hours, "Open now / Opens at 12:00" and the next exception. A page showing "now" is cached only until the next change of state.
- **Dated items:** any data row may carry `shows_from` and `shows_until`. A row past its date stops showing, with no update needed.
- **Search data:** the schedule feeds SM1357's opening hours.

# Questions for ruling

1. Should exceptions be kept after they pass, or removed after a set time?
