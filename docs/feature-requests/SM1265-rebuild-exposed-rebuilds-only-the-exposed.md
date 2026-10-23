---
id: SM1265
title: "SM1265: --rebuild-exposed rebuilds only the sites in the X-Forwarded-For failure"
subtitle: "A site whose front end passes the client's X-Forwarded-For through to a site that trusts forwarded addresses lets any visitor choose their address. The Hestia updater gains an opt-in --rebuild-exposed that rebuilds only those sites, inside the run and before the deploy, so the permission pass and the repair follow."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: "the release manager (task #379 part 2, ruled option B on 2026-10-22)"
area: installers
status-note: "SHIPPED (0.16.1) on n724: rebuild_exposed and the --rebuild-exposed step in lazysite-hestia-update-all.sh; the FAILURE names the flag. t/tools/265."
---

# What happened

#379 part 2 asked whether the updater should rebuild a vhost unasked when both hold: it
renders an older lazysite template, and the site trusts the default ranges. That is the
X-Forwarded-For pass-through FAILURE (SM1194, `xff_exposure`). Until now the fix was
`--rebuild`, which rebuilds every site, or a manual `v-rebuild-web-domain`, which
resets the docroot permissions (SM270) unless a repair follows.

The options were left for the release manager: the status quo (A), an opt-in flag (B),
B on by default (C), or writing `trusted_proxies: none` instead of rebuilding (D). The
ruling was B.

# What shipped

- `lazysite-hestia-update-all.sh --rebuild-exposed`. After Hestia's template copies are
  refreshed (SM1196) and before the deploy, it runs `v-rebuild-web-domain` for each
  in-scope site that `xff_exposure` reports, and for no other site. A site on an old
  template that is not exposed (`trusted_proxies: none`) is left alone.
- The deploy's permission pass and the health phase's repair then follow, as they do
  for `--rebuild`.
- Each rebuilt site is logged as `auto-rebuilt` on the transcript and among the
  findings. A rebuild that fails is a REBUILD FAILED line, and the deploy still runs.
- With `--rebuild` as well there is nothing left to do, so the step is skipped.
- Without the flag, the FAILURE line's fix names `--rebuild-exposed` first. With the
  flag, a site that is still exposed after its rebuild says that Hestia's copy of
  `lazysite-proxy` is not the release's.
- Refused alongside `--list` (exit 2), which promises to change nothing.
- Documented in UPGRADE.md, beside the SM1196 template note.
