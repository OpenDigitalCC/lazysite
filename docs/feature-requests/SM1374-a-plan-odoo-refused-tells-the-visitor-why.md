---
id: SM1374
title: "SM1374: a plan Odoo refused tells the visitor why, in Odoo's words or plainly"
subtitle: "A failed Odoo plan answered 'the plan did not apply completely - see the counts', an operator's sentence, and carried Odoo's message whatever the fault. A validation error now shows Odoo's own words; any other failure a plain sentence, its text withheld."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-06
raised-by: "release manager (triage T-62)"
area: odoo
status-note: "SHIPPED (PENDING) on n759: a validation or user error shows Odoo's message without the prefix, validation: 1; any other failure answers a plain sentence and its text is withheld; counts stay in result, journal and log. Register entry confirmed (ruling 140). t/unit/odoo/125, 77."
---

# What happened

An Odoo plan that failed at Odoo (`apply-incomplete`, `_finish` in
`lib/Lazysite/Odoo.pm`) answered "the plan did not apply completely - see the
counts", a sentence for an operator, not the visitor who sent the data. Each failed
change carried Odoo's message through SM1186's filter whatever kind of fault it was,
so an access error's text (a model and the groups that may reach it), a missing
record's id or an unclassified server fault could reach a public binding's visitor.

# What shipped

- **Validation in Odoo's words.** `_applied_changes` reads each journal entry's
  error kind and OOM category (`fault_category`) into a map by change. A failed
  change shows its message only when the category is `validation`
  (ValidationError, UserError), with OOM's "Odoo Server Error:" prefix taken off,
  and is marked `validation: 1`. The answer's `error` is the first such message.
- **Anything else, plainly.** Any other failure, or one whose journal cannot be
  read, is withheld from the change, and `error` is "The change was not saved. Try
  again, or tell the site's operator."
- **A refusal the operation raises itself** (kind `refused`, SM1198) keeps its
  sentence.
- **For the operator.** The counts stay in `result` and the journal, and a WARN log
  line carries the binding, operation, plan and counts, never a change's text.
- **Unchanged:** a change whose answer never came (`unknown`, SM1218).

The Odoo manual's paragraph says the new rule.

# Tests

t/unit/odoo/125 (fakes only) covers UserError and ValidationError (shown, prefix
gone) and AccessError, MissingError and an unclassified fault, whose text appears
nowhere in the answer; it fails with the change reverted. t/unit/odoo/77's first two
subtests, which asserted that an unclassified fault's text reached the change, now
assert it is withheld, through the real oomd.

# Security

docs/SECURITY.md, the 2026-11-06 SM1374 entry: Information disclosure narrowed, no
ADR 0007 trigger, confirmed by the release manager (ruling 140).
