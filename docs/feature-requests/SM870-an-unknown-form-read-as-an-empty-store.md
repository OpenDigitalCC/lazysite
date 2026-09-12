---
id: SM870
title: "SM870: asking for the submissions of a form that does not exist answered ok:true, total:0, naming a file that was never created"
subtitle: "The store for an unknown form resolves to the DEFAULT directory, so the path is well-formed and simply absent - and absent read as empty. SM855's own shape one level up: a wrong-place read reported as nothing there. It matters because the operator approving registrations reads submissions by form name."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-12 for 0.13.15. `action_form_submissions` checks the form's conf exists before resolving its store, and answers 404 `kind: not-found` naming the form. A form that EXISTS with no submissions yet still reads as empty - absent FORM and absent STORE are different facts and only one is a refusal, which t/unit/manager/188 asserts as a pair."
raised: 2026-09-12
raised-by: site agent (1314E-02, "two absences that answer oddly")
area: forms
---

# What was found

In the same pass, in the code SM862 shipped that morning:

> "`form-submissions&form=<a form that does not exist>` answers **200**,
> `ok: true`, `total: 0`, naming a `.jsonl` that was never created. An absent
> form reads as an empty store. That is one level up from the bug you just
> fixed, and the same sentence applies: a wrong-place read reported as nothing
> there."

They are right about the shape and right about the lineage. SM855 was a read from
the wrong file answering `total: 0`; this is a read for a form that does not exist
answering the same way.

# Why

`form_store_dir` returns the default submissions directory for any name it cannot
resolve to a file handler with its own `path:`. That is correct for its own job -
a form bound to the default store *does* live there. But it means an unknown form
name produces a **well-formed path to a file that does not exist**, and the
absent-file branch answers with an empty store, because for a real form with no
submissions yet that is exactly the right answer.

Two different facts arrived at the same branch:

- a form that exists and has no submissions yet - **empty, correctly**
- a form that does not exist at all - **not found**, and it was reported as empty

# Why it matters for the expo

The operator approving registrations reads submissions **by form name**. So a
form that was renamed, or a name mistyped, tells them nobody has registered -
and "nobody registered" is a conclusion they will act on by doing nothing. The
failure is silent in the worst possible direction.

# The fix

Check the form exists before resolving its store:

```perl
my $fc = _handlers_module()->can('form_file')->($form);
return { ok => 0, kind => 'not-found',
    error => "no form named '$form' - check the name against form-list" }
    unless defined $fc && -f $fc;
```

`form-list` is named in the message because it is the answer to the question the
operator now has.

**The empty answer for a real form is untouched**, and that is the assertion that
matters: `t/unit/manager/188` tests both cases as a pair, so a fix that made
every absent store a refusal would fail. It failed on all three assertions of the
not-found case before the change.

# Not fixed here, and said so

The site agent reported a sibling in the same breath:
`data-table&table=<absent>` answers **400** `kind: no_such_table` where an absent
record should be **404**. It is the same family and it is **not** in 0.13.15: it
is pre-existing rather than a regression, it is a status-only change, and this
release was cut to a deadline with the smallest defensible scope. Recorded here so
it is not lost, and it belongs with SM854's status work.

# Related

[[SM855]] (the same shape one level down - the read that started this), SM862
(which added the `form=` parameter this defect is reached through), SM854 (the
status work the `data-table` sibling belongs with),
[[feedback_absence_is_a_finding]] (doesn't-exist is not says-none).
