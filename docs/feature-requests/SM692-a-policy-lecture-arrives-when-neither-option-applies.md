---
id: SM692
title: The Migrate/Rebuild explanation appears when neither applies
raised: 2026-08-29
raised-by: release manager
area: manager-ui
status: shipped
status-note: "SHIPPED in 0.11.6. The migration panel opened with a paragraph distinguishing Migrate from Rebuild, emitted unconditionally BEFORE the plan was known - so the commonest case read as a policy lecture followed by 'Nothing to do'. The only time it was certain to be read was the one time neither option applied. Now held back and shown only when one of the two buttons is actually offered, which is exactly when an operator has to tell them apart."
---

# What the operator saw

> **Migrate** applies only changes that keep every row - it refuses anything
> that could lose data. **Rebuild** makes the descriptor true whatever that
> costs: it names each column it would drop, and writes a safety export first.
>
> The stored table already matches the descriptor. Nothing to do.

The release manager's response was the right one: *"i dont think this button
should even be here, i am not sure what this information does for me. surely at
migrate it is the only time to run these evaluations."*

# Why it was wrong

The paragraph explains a **choice**. It was printed before the panel knew
whether there was a choice to make, so the reader most likely to see it was the
reader for whom neither option existed.

That is worse than noise. An operator reading a careful distinction between two
destructive-sounding operations, immediately followed by "nothing to do", learns
that the panel talks past them - and the next time it says something that DOES
matter, they have been trained to skim it.

The information itself is good and stays. Migrate refusing anything that could
lose a row, and Rebuild naming each column it would drop, are exactly what
somebody needs before pressing either. They need it **at the point of pressing**.

# The fix

The explainer is held back and prepended only when `plan-migrate-btn` or
`plan-rebuild-btn` is actually on offer. When the table already matches its
descriptor the panel says so and stops.

# The general rule this is an instance of

Explain a choice where the choice is. Text that describes what two buttons do
belongs with the buttons, and a page that shows it when neither is available is
answering a question nobody asked.

Same shape as [[SM686]] (a hint marker rendered as a question mark in the label
text, so the grid appeared to be asking rather than offering) and SM635 (say
what is true where the operator is looking). The recurring error is putting
guidance where the code found it convenient rather than where the reader needs
it.

# Related

DM-5 (the descriptor is edited as text, and saving never migrates - the panel
this sits in), [[SM686]], SM635.
