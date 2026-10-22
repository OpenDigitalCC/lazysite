---
id: SM1259
title: "SM1259: a certified cut gets past the manifest build"
subtitle: "release.sh --certified passes --channel certified to build-manifest.pl, which accepted only edge, beta and stable. It takes the fourth rung now."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: found beside SM1256 on n728, ruled for build by the coordinator 2026-10-22
area: release
status-note: "SHIPPED (PENDING) on n728: tools/build-manifest.pl accepts --channel certified; t/tools/213."
---

# What happened

ADR 0010 made the ladder edge < beta < stable < certified, and
`tools/release.sh --certified` sets `CHANNEL="certified"` and passes it to
`tools/build-manifest.pl --channel`. build-manifest checked the value against
`^(?:edge|beta|stable)$` and died, so the first certified cut would have
stopped at the manifest build. No certified cut has been made, which is why it
was not met. install.pl already ranks `certified` (`%CHANNEL_RANK`), so a
manifest carrying it is one the installer reads.

# What shipped

The check takes the four rungs and names them in its refusal, as
`lazysite-hestia-domain` does since SM1256. The manifest records the channel as
before.

# Found beside it, not changed

`Lazysite::Manager::Config` refuses `update_channel: certified` on a config
set (`^(?:all|edge|beta|stable)$`), although ADR 0010 says a site that requires
certification sets exactly that. Raised for the release manager.

# Tests

t/tools/213 builds a manifest from the tree into a scratch file with
`--channel certified` (exit 0, `channel: certified` recorded), and with an
unknown channel (refused, naming the four). With the old build-manifest.pl, the
certified build and the refusal text fail.
