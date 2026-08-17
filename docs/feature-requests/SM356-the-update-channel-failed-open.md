---
title: "SM356 - the update channel failed open, and a typo granted more than the word it misspelled"
subtitle: "`update_channel: stabel` did not fail, did not warn, and did not mean stable. It meant `all` - accept every build including edge - because an unrecognised value fell through to the most permissive rung in silence."
brand: plain
status: shipped
status-note: "FILED AND FIXED 2026-08-17, out of the release manager's report that an edge rollout touched sites it was not for. [[SM345]] fixed the phases that were not channel-scoped; this is the other half - the gate itself worked, and the DEFAULT was wrong. A default that is wrong in the permissive direction is indistinguishable from having no default. Three separate fall-open paths, and the dangerous one is the typo: the only symptom of getting it wrong is a pre-release build arriving on a customer site, which reads as a rollout problem rather than a spelling one."
---

# Three ways to fail open

`read_update_channel` returned `all` - accept everything, edge included - in
three cases:

```datatable
columns: Case | Returned | Should be
widths: 6.4cm | 2.6cm | X
bold: 1
tone: medium
---
The conf could not be read | `all` | the safest rung
No `update_channel` line | `all` | the safest rung
**The value was not recognised** | `all` | **the safest rung, and say so**
---
```

And `channel_refuses` had the same shape twice more:

```perl
my $need = $CHANNEL_RANK{$site_channel}                      // 0;
my $got  = $CHANNEL_RANK{ lc( $release_channel // 'edge' ) } // 0;
```

`0` is `edge`. So any rung either side failed to recognise resolved to *install
it*. **A comparison whose unknown case is the permissive one is not a gate.**

# Why the typo is the one that matters

`update_channel: stabel` is a plausible thing to type. It did not fail, did not
warn, and did not mean `stable` - it meant the most permissive setting
available.

An operator who typed the word they meant, with one letter wrong, got the exact
opposite of what they asked for. And the only symptom is a pre-release build
turning up on a customer site, which looks like a rollout problem rather than a
spelling one - so the investigation starts in the wrong place.

The control API validates this key on write (`^(?:all|edge|beta|stable)$`), so a
typo can only arrive by hand-editing the conf. That is exactly the case worth
catching, because it is the one no other surface is watching.

# `all` was reached by accident

`%CHANNEL_RANK` did not contain `all`. It worked only because `// 0` caught it -
the same way it caught a typo. **A rung reachable only by failing to recognise
something cannot be told apart from a mistake**, which is why the two were
indistinguishable in the first place.

# The fix

- `all` is a declared rung, not a fall-through.
- A recognised value is honoured; everything else falls to **`stable`**, the most
  restrictive rung. The safe direction for a control whose failure mode is
  installing a pre-release build on a customer site.
- An unrecognised value is **reported** as well as corrected. A typo silently
  fixed to something safe is still a setting that does not do what it says, and
  the operator should learn that from the rollout rather than from a support
  question months later.
- Both sides of `channel_refuses` fail closed on an unknown rung.
- The fleet updater prints each site's channel, so the fleet's actual policy is
  legible instead of inferable from which sites got skipped.

## What changes for existing sites

A site with **no** `update_channel` line stops accepting edge and beta builds.
That is a real behaviour change and it is the intended one - an unconfigured
site should not be taking pre-release code. Provisioning already writes
`update_channel: stable`, so only sites predating that are affected, and
`install.pl --channel` sets it explicitly.

# Verification

- A site whose channel reads `stabel` refuses an edge build, refuses a beta
  build, and still accepts the stable build it was trying to ask for.
- A site with no channel refuses edge and accepts stable - safe, not frozen.
- Every recognised rung behaves exactly as before.
- No `$CHANNEL_RANK{...} // 0` remains.
- A rollout names each site's channel.

# Related

[[SM345]] (the other half - the phases that ignored the channel entirely),
[[SM344]] (the verdict that conflated a failed rollout with a fleet finding),
and `install.pl --channel`, which is how a site is told what it accepts.
