---
title: "SM831: the spelling as sent is lost before the audit log and the error message"
subtitle: "Sites agent, 1311E-06, 2026-09-10: four paired calls, all four audited as plugin-*, and 'extension' appears nowhere in fifty entries - so the question the deprecation exists to answer cannot be asked"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-10 (fa434f3e). The spelling as sent reaches the audit record as a FLAG beside the canonical action name - a second action name would have split one act across two spellings for every deployed reader - and every refusal echoes the verb the caller typed. The error half is tested behaviourally through subprocess calls; the audit half is asserted from the source, because every plugin-*/extension-* action is cookie-only and the suite has no fixture that mints a manager session."
---

# What was measured

`plugin-action` and `extension-action`, then `plugin-save` and
`extension-save` - one call each. The audit log:

```
14:28:21  plugin-save    fail  /  invalid
14:28:21  plugin-save    fail  /  invalid
14:28:21  plugin-action  fail  /  invalid
14:28:20  plugin-action  fail  /  invalid
```

Two and two, all four under the old name. Nothing in 10,772 bytes of audit
across 50 entries contains the string `extension`.

# Why this matters more than it looks

**You deprecate a spelling in order to retire it, and the retirement decision
needs evidence.** The question is "is anyone still calling the old one", the
audit log is where an operator would look for the answer, and it currently
cannot give one - both spellings arrive as `plugin-*`.

So [[SM817]] shipped the compatibility and lost the instrument that tells us when
compatibility can end. The INFO line was meant to be that instrument, and it
answers a different question: it fires on the old spelling, which tells you the
old spelling was used, but it is a log line on a host that a remote operator
has no route to (see [[SM835]]).

# The same cause, a second symptom

Refusals report the normalised verb rather than the one the caller typed:

> Unrecognised action name: **'plugin-nosuchthing'**

for `extension-nosuchthing`, and

> Action not available to token clients: **plugin-list**

for `extension-list` over the token channel. Someone migrating to the new
spelling gets errors naming a verb that appears nowhere in their code, and
greps for it fruitlessly.

# The shape, which is small

`$action_as_sent` **already exists**, captured at the single point the action is
read and immediately before normalisation - it was added by SM817 for the
deprecation INFO. It is simply not carried any further.

Two places want it:

1. **The audit record** - the spelling as sent, or a flag beside the normalised
   name. A flag is probably better: it keeps one canonical action name for
   counting and adds one boolean for the retirement question.
2. **The error text** - refusals echo what the caller typed. The gate and the
   dispatch keep working on the normalised name; only the message changes.

Nothing below the normaliser needs to learn a second spelling, which was the
property SM817 was built to protect and which this preserves.

# Related

[[SM817]] (the rename, whose remaining steps this belongs with - same code path,
same purpose), [[SM835]] (no route to the engine log, which is why the INFO could
not be quoted).
