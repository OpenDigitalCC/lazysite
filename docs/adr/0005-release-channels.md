# 0005 - Edge and stable release channels

Status: Accepted
Date: 2026-07-02 (retrospective; shipped 0.5.x "update channel" work)
Tags: release, channels, deployment

## Context

One codebase serves both the operator's own rapidly-iterating sites (fixes
verified live within hours) and customer sites that must only ever receive
certified builds. A single release stream forced a choice between speed and
safety.

## Decision

Every release carries a **channel** in its manifest: `edge` by default;
`stable` only when cut with `release.sh --final`. Each SITE declares
`update_channel:` in `lazysite.conf` (`all` accepts everything; `stable`
refuses non-stable upgrades). The refusal happens in the installer
(`install.pl --channel-check`, exit 3 = clean skip) BEFORE any filesystem
change, and the skip is recorded in the site's audit trail.

## Rationale

The operator's own sites act as the soak environment for edge builds; customer
sites ratchet only on deliberate stable cuts. Putting the gate in the
installer (not the deploy script) makes the policy hold regardless of how the
tarball arrives.

## Consequences

- Edge cadence stays high (multiple releases/day during active work) without
  customer exposure.
- Cutting a stable release is an explicit act (`--final`), which is also where
  the pre-launch compliance artefacts (signing, DoC) will attach.
- A site's channel is itself operator-config, auditable like any other key.
