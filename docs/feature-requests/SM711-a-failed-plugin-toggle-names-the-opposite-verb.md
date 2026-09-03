---
id: SM711
title: A failed plugin toggle names the opposite verb, and the audit row carries no reason
raised: 2026-09-01
raised-by: edge-testing agent (0.11.9 regression round 2)
area: manager-ui
status: shipped
status-note: "PARTIAL. THE VERB IS FIXED: the message now derives from `action`, computed before the revert, instead of from the checkbox the line above puts back. HALF 2 IS DONE 2026-09-03 - see the note at the end of this filing. Previously: HALF 2 REMAINS: the audit row for a refused toggle is still `plugin-enable / pandoc / fail` with no reason, while the banner beside it carries the full explanation. That is the release manager's 'the logged error doesn't say which dep is missing' and it is not a one-line change - the reason has to be carried into the audit entry's detail at the point of refusal. The refusal TEXT itself is good and is quoted in this filing so it does not get 'improved' by someone reading only the defect list."
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

# Half 2, shipped 2026-09-03

The audit row for a refused toggle now names what is missing.

`_missing_deps` returns the bare names alongside the operator's sentence,
`action_plugin_enable` puts them in `audit_detail` as
`missing_deps: YAML::PP, pandoc`, and the dispatcher's audit block prefers
`audit_detail` over `kind`. The row that said `missing_deps` now says which.

**The prose is not reused, and that is the decision.** The operator's message
is three sentences with install advice in the middle - right for a banner,
wrong for a column an auditor scans. Deriving the trail's version from it would
have meant parsing prose we had just finished formatting, which is cheap and
wrong in the way this project keeps finding: a dependency's own wording becoming
something else's data. So the names travel separately.

`t/unit/manager/152` covers both halves, because neither is visible from the
other file: that the check returns bare names for BOTH kinds of dependency - a
Perl module and a program - and that the dispatcher actually prefers the
detail. Its second assertion strips comments first, because the block it reads
explains `audit_detail` in prose and a search that cannot tell code from prose
about code would have passed on the explanation alone.
