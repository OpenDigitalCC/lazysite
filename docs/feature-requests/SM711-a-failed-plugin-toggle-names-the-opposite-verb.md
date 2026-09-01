---
id: SM711
title: A failed plugin toggle names the opposite verb, and the audit row carries no reason
raised: 2026-09-01
raised-by: edge-testing agent (0.11.9 regression round 2)
area: manager-ui
status: candidate
---

# Two defects on one journey

Enabling the Branded PDF plugin on a host without `md-to-pdf` produces a
refusal. The refusal itself is good and should be left alone - it names the
missing program, says what would have happened, and leaves the toggle off:

> This plugin needs md-to-pdf (a program, not a Perl module - Debian:
> md-to-pdf) and they are not installed. It would enable and then fail on every
> request... so it has been left off - install them and enable it again.

What is wrong is everything around it.

## 1. The banner names the opposite action

The banner opens **"Failed to disable Branded PDF creation"**. The action was
enable.

`starter/manager/plugins.md`, in `togglePlugin`:

```js
if (!data.ok) {
  input.checked = !input.checked;                                    // line 92
  warn('Failed to ' + (input.checked ? 'enable' : 'disable') + ...   // line 93
}
```

The checkbox is reverted on line 92 and then **read on line 93** to choose the
verb, so the verb always describes the state it was put back to rather than the
action that failed. `action` is already computed correctly on line 84 and is
what the message should use.

Not cosmetic: an operator reading "failed to disable" while trying to enable
reasonably concludes the UI has lost track of which way the switch is, and the
real reason - which is in the same banner - gets read as noise.

## 2. The audit row does not carry the reason

The banner is rich; the audit entry is `plugin-enable / pandoc / fail` and the
row's only tooltip is its ISO timestamp. **This is the release manager's
"the logged error doesn't say which dep is missing"** - accurate for the audit
surface, and probably the server log too.

The reason exists at the moment of refusal and is simply not propagated into the
audit detail. A `fail` row that cannot explain itself sends whoever reads it
later back to reproduce the failure to find out what it was.

# Test that would have caught it

An outcome test on the refusal path asserting the banner text contains the verb
of the ATTEMPTED action, not the resulting checkbox state - and that the audit
entry for a refused toggle carries a non-empty reason.
