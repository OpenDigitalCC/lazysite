---
id: SM1260
title: "SM1260: a site can be put on the certified channel from the manager"
subtitle: "config-set refused update_channel: certified and the Config page did not offer it, though ADR 0010 says a site that requires certification sets exactly that. Every channel validator in the tree was checked."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: found beside SM1259 on n728, ruled for build by the coordinator 2026-10-22
area: manager
status-note: "SHIPPED (PENDING) on n728: Lazysite::Manager::Config accepts certified; the Config page offers it; t/unit/manager/17 and t/tools/214."
---

# What happened

`Lazysite::Manager::Config`'s config-set check took `^(?:all|edge|beta|stable)$`
for `update_channel`, and the Config page's select offered `all`, `beta` and
`stable` - while the same field's note already described `certified`. The
control API's `config-set` and the manager page both go through that check, so
neither could put a site on the rung ADR 0010 added, though install.pl ranks it
(`%CHANNEL_RANK`) and honours it on every upgrade.

# The sweep

Every place in the tree that validates a channel against a list, read and, where
it already took certified, run:

| Where | Before | Now |
|---|---|---|
| `Lazysite::Manager::Config` (config-set: manager UI, control API) | refused certified | accepts it (this change) |
| `starter/manager/config.md` select options | no certified | offers it (this change) |
| `tools/lazysite-hestia-domain.pl add --channel` | refused | accepts it (SM1256) |
| `tools/build-manifest.pl --channel` | refused | accepts it (SM1259) |
| `install.pl --channel`, `read_update_channel` (`%CHANNEL_RANK`) | took it | unchanged; now pinned by t/tools/214 |
| `tools/lazysite-cli.pl channel` and `provision --channel` | took it | unchanged; `channel` now pinned by t/tools/214 |
| MCP | has no tool that sets the channel | - |

The Hestia deploy scripts' skip messages say "stable channel, edge build"
whatever the rungs were; that is wording, not validation, and is left.

# Tests

- t/unit/manager/17: config-set takes all, edge, beta, certified and stable,
  refuses an unknown value naming certified, and takes every option the Config
  page's schema offers, which include certified. With the old Config.pm and
  config.md, the certified case, the refusal text and the page check fail.
- t/tools/214 runs install.pl `--channel certified` and `lazysite channel
  certified` on a site: each writes the value and refuses `gold` leaving the conf
  as it was. These already worked; the test holds them.
