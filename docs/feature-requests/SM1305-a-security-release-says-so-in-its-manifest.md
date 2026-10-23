---
id: SM1305
title: "SM1305: release.sh cuts a security release"
subtitle: "`lazysite upgrade --all --force-security` acts only on a release whose manifest declares security_critical, and the only way to write that key was build-manifest.pl by hand - release.sh, which builds every release, could not ask for it. It takes --security-critical now."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-23
raised-by: "ruling 41b (2026-10-23): 0.16.2 is cut marked security_critical, release.sh gaining --security-critical"
area: release
status-note: "SHIPPED (PENDING) on n738: tools/release.sh --security-critical passes the flag to build-manifest.pl; OPERATOR.md and docs/development.md say how a security release is cut. t/tools/104."
---

# What was asked

Ruling 41b routes the theme-archive fix (SM1303) out as 0.16.2, marked
`security_critical` and pushed fleet-wide with `lazysite upgrade --all
--force-security`. That override is only as strong as the release's own
declaration (SM139): against a manifest without `"security_critical": true` it
refuses before touching any site. `tools/build-manifest.pl --security-critical`
writes the key, but `tools/release.sh`, the one way a release is gated, built and
packaged, had no way to ask for it, and refused the flag as unknown.

# What shipped

- **`tools/release.sh ... --security-critical`.** Accepted by `gate` and `build`,
  which both build the manifest; on `build` it is the manifest that ships in the
  tarball and the packages. It is passed to `build-manifest.pl` as
  `--security-critical`, and the build's manifest line says so:
  `==> build-manifest.pl (channel: edge, security-critical)`. Without the flag
  nothing changes: the manifest carries no `security_critical` key.
- The script's own usage says what the flag is for. OPERATOR.md's "Security
  releases" paragraph names the `release.sh` command, and `docs/development.md`
  gives it beside Build and in the step table.

The gate receipt does not record the flag: it marks what ships, not what was
tested, so a security build takes the same receipt as any other.

# Tests

- t/tools/104, the real release.sh in a scratch repository: a build with
  `--security-critical` ships a manifest with `"security_critical":true` and says
  so; a build without it ships none. The stand-in build-manifest.pl writes the key
  only when given the flag, as the real one does (t/tools/29). With release.sh as on
  main the flagged build is refused as an unknown flag; with the flag taken but
  not passed on, the manifest lacks the key.
