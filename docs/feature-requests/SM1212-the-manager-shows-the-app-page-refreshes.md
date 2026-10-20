---
id: SM1212
title: "SM1212: the manager shows the app's page refreshes"
subtitle: "SM1203 counted the installed app's own page fetches as app_hits in the day rollup and nothing read them. The Stats page, the window and month answers carry the figure now."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: the release manager (open item of SM1203)
area: stats
status-note: "SHIPPED (0.15.15) on n700: plugins/stats.pl (window view, export totals, month rollup), starter/manager/stats.md (App page refreshes tile), starter/docs/ai-briefing-stats.md; t/unit/plugins/51, t/unit/manager/375."
---

# What happened

SM1203 recorded the installed app's keeping fetches on the `app` channel and counted
them in the day rollup as `app_hits` and `app_by`. Its open item: nothing outside
`plugins/stats.pl` read them. The window view the Stats page draws, the window answer
of the export (the control API and MCP `analyse_visitors`) and the month rollup
did not carry them, so a window of days showed no trace of the fetches.

# What shipped

- The window view and the export's `totals` carry `app_hits`, and each month carries
  it, summed over the days the way the other counters are, beside `pageviews` and
  never inside it.
- The field is left out when the app made no fetches, so a site without the app
  sees no new field.
- The Stats page draws an "App page refreshes" tile beside Images and files when
  the figure is above zero.
- `starter/docs/ai-briefing-stats.md` lists where the figure appears.

# Left as it is

`registry_hits` is in the day rollup only; the window and month answers do not
carry it and the manager does not show it. That is not changed here.
