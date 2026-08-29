---
id: SM690
title: A partner brief promises capabilities the grant does not carry
raised: 2026-08-29
raised-by: edge-testing agent
area: partners
status: candidate
status-note: "OPEN. Measured on 0.11.5: `claude-code-3`'s brief says it holds `manage_domains`; whoami said false. `claude-code-2`'s brief lists only `manage_users` + webdav while the account needed `manage_forms` and did not have it. A cold agent trusting the brief attempts the work, reads a CORRECT refusal as breakage, and may spend a single-use pairing key before discovering the grant is not what it was promised. The briefs already say the server is authoritative; the Capabilities section reads as a promise rather than a hint, which is where it misleads."
---

# What was measured

The edge-testing agent's preflight compared each partner brief's Capabilities
prose against `whoami` on the same account:

| Account | Brief says | `whoami` says |
| --- | --- | --- |
| `claude-code-3` | holds `manage_domains` | **false** |
| `claude-code-2` | `manage_users` + webdav | needed `manage_forms`, **absent** |

# Why it costs more than a wrong sentence

A brief is what a COLD agent reads before it has any other source. Three things
follow from a brief that overstates the grant:

1. **A correct refusal reads as a defect.** The agent attempts the work the
   brief describes, is properly refused, and files a bug against a gate that is
   behaving exactly as designed. That is the expensive failure: it costs the
   agent's run and an engine investigation.
2. **It can spend a single-use key.** Pairing keys are single-use and
   short-lived ([[SM691]]). An exchange spent discovering that the grant is not
   what the brief said is an exchange that has to be minted again by the
   operator.
3. **It teaches agents to distrust the brief.** Once an agent learns the
   Capabilities block may be wrong, the whole document drops to advisory,
   including the parts that are load-bearing.

# The shape of the fix

Two honest options; the operator picks.

- **Generate it from the grant.** The Capabilities block is rendered from the
  capabilities actually granted at issue time, so it cannot drift from them. It
  can still drift AFTER issue - a grant changed later leaves the brief stale -
  so it should be dated and say so.
- **Demote it to a hint, in the document's own words.** Keep the prose, but say
  plainly at the top of that section that it is indicative and `whoami` is
  authoritative, and that a preflight is expected. Cheap, honest, and it stops
  the block reading as a promise.

The second is nearly free and removes the misreading; the first removes the
divergence. They compose: generate it, and still say when it was true.

# What already works and should be kept

The briefs already state that the server is authoritative. The edge agent's
preflight now checks capabilities as well as scope and channel, and that is what
caught this - so the practice caught the defect the document invited.

# Related

[[SM691]] (the pairing key, where a wasted exchange is paid for),
[[reference_capability_row_testing]]-adjacent: naming the grant a result was
proved under is the same discipline applied to results rather than to briefs.

# Not started
