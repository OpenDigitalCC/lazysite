---
id: SM1314
title: "SM1314: a security release is cut on stable"
subtitle: "0.16.2 was cut security-critical on edge, so the standard deploy reached the edge sites only and the rest were pushed by hand. Ruling 45: a security release is cut on stable. release.sh refuses --security-critical without --final."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-04
raised-by: "release manager, ruling 45 (after the 0.16.2 rollout)"
area: release
status-note: "SHIPPED (0.16.3) on n740: tools/release.sh refuses --security-critical below stable (exit 2), before a receipt is read. t/tools/104."
---

# What happened

0.16.2 was a security release - its manifest declares `"security_critical":
true` (`tools/release.sh build 0.16.2 --security-critical`, SM1305) - and it was
cut on the edge channel. The deploy hook (`tools/lazysite-deploy.sh`) runs the
Hestia updater, which scopes each site by its `update_channel` (SM345), so the
release reached the edge sites and nothing else. The operator then pushed it to
the rest by hand with the updater's `--force-security` (SM1307).

Ruling 45: a security release is cut on the STABLE channel (`--final`), so the
standard deploy hook applies it to every site.

# What shipped

- **`tools/release.sh build X --security-critical` refuses (exit 2) unless
  `--final` is also given.** The message says a security release is cut on
  stable so the standard deploy reaches every site, and names what the refused
  cut would have reached. The check runs straight after the arguments are
  parsed, before a receipt is read or a stage made, so main and the tags are as
  they were. It applies to `gate` too, where the flag has no other effect.
- **`--certified` is accepted with it.** Certified is above stable on the ladder
  (ADR 0010); a certified build is accepted by every site, certified ones
  included.
- Docs: the usage header of release.sh, OPERATOR.md "Security releases",
  UPGRADE.md and docs/development.md give the stable form.

# Tests

- t/tools/104 drives the real release.sh in a scratch repository. A build with
  `--security-critical` on edge and on `--beta` is refused with exit 2 and the
  ruling's wording, leaving main and the tags untouched; `--certified` is not
  refused for it. The SM1305 subtest now cuts on stable (`--final`), with and
  without the flag, and reads the shipped manifest back from the tarball.
- With release.sh as on main, the refusal subtest fails (both channels build and
  tag).
