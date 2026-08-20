# 0010 - A certified channel above stable; the conformity gates attach there

Date: 2026-08-20
Status: Accepted
Tags: release, channels, compliance
Amends: 0005 (release channels), 0007 (pentest deferral - the gate's home)

## Context

ADR 0005's ladder was edge < beta < stable, and `release.sh` described stable
as "the certified customer-rollout channel" - one word carrying two meanings.
The compliance gate blocked a STABLE cut on the signed Declaration of
Conformity, the restore rehearsal and the walked registers.

Two pressures exposed the conflation. First, the compliance work is
deliberately deferred-and-tracked (release-manager instruction, 2026-08-19):
the records matter and will be completed, but must not block progress until
explicitly required - yet the next stable cut WOULD block on them, making
"stable" hostage to paperwork that has its own timeline. Second, the first
stable line (0.7.x) shipped with a pentest waiver and an unsigned declaration
anyway - so "stable = certified" was already untrue in practice, and a label
that is untrue in practice is the defect class this project keeps burning
down.

## Decision

The ladder gains a fourth rung: **edge < beta < stable < certified**
(`%CHANNEL_RANK`: 0/1/2/3; `release.sh --certified`; `update_channel`
accepts it).

**stable** means supported software: gated, bedded in, the customer-rollout
default. **certified** means a stable-quality build whose compliance records
have been WALKED - the signed Declaration of Conformity, the restore
rehearsal for the cycle, the registers current, the pentest posture per ADR
0007. The conformity gates in `lazysite-compliance.pl` block a certified cut
and are advisory everywhere below; `signoff_required: yes` attaches to a
certified cut.

A site's `update_channel` works unchanged: it is the MINIMUM maturity
accepted, so a `stable` site takes certified builds (rank 3 ≥ 2), and a site
that requires certification sets `update_channel: certified`.

## Consequences

- Future stable cuts stop blocking on the declaration; the deferred
  compliance work has a home with a name, and certifying is a deliberate act
  with its own cut rather than a hurdle inside someone else's.
- The dated obligations are UNMOVED: 2026-09-11 (CRA) and 2026-12-31 (ADR
  0007 waiver expiry) bind the project, not a channel. A certified channel
  that never gets used does not discharge them - it only locates where the
  release process checks.
- `docs/compliance/SIGNOFF.md`, the compliance tool's POD, and the operator
  docs say "certified" where they said "stable"; release.sh's description of
  stable loses the word "certified".
- The first certified cut will be the first release whose gate demands the
  walked records - a planned stop, one rung above where it used to sit.
