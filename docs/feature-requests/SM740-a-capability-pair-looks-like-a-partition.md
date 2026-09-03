---
id: SM740
title: "SM740: a capability pair looks like a partition when it is a hierarchy"
subtitle: "whoami presents manage_data and write_data as two independent booleans. They are ANY-OF halves of one right, so withholding the weaker one changes nothing - and the presentation is what invites an operator to think it does."
brand: plain
standard-margins: true
status: candidate
---

# The moment this fills

The field agent filed `data-row-save` as a capability-gate defect: a grant
holding `manage_data` and **denied** `write_data` wrote a row and read it back.
Airtight evidence, cleaned up afterwards.

**It is not a defect.** The gate is `manage_data` **OR** `write_data`, the
ANY-OF semantics declared in SM662. The two are a hierarchy: `manage_data` is
the stronger right and admits the weaker action by design.

But the report was still worth its weight, because the reasoning that produced
it is the reasoning an operator will use:

> `write_data` appears in `whoami` and in `describe-capabilities` as its own
> boolean. So it must gate something of its own. So withholding it must stop
> something.

It stops nothing that `manage_data` does not already admit. **A deployment that
grants `manage_data` and withholds `write_data` to hold back row writes is not
being enforced** - not because the gate is wrong, but because the presentation
described a partition and the model is a hierarchy.

# Why this is the engine's fault and not the reader's

Two capabilities rendered as sibling booleans carry an implicit claim: that each
one is separately meaningful, and that turning one off subtracts something.
`whoami` makes that claim about every pair it prints, including the pairs where
it is false.

The agent who filed this reads capability output for a living and reached the
wrong conclusion from correct data. That is the test a presentation fails.

# What would fix it

The output has to say which capabilities **imply** others. Sketch, not a
specification:

- `whoami` marks a capability that is held **by implication** distinctly from one
  held **directly** - so `write_data: true (implied by manage_data)` rather than a
  bare `true`, and a withheld capability that is nonetheless satisfied by a
  stronger one never reads as withheld.
- `describe-capabilities` names the implication in the description of the weaker
  right, so "what does withholding this achieve" is answerable from the document.

The answer to "what does `write_data` gate" should be legible without reading
the source: the same actions, at a lower level of privilege. It is what you grant
for row writes **without** table administration.

# Could a lint have caught it

The field agent proposed a check that every declared capability is enforced
somewhere, which would have flagged `write_data` as enforced-nowhere.

**It must understand ANY-OF or it will be wrong here.** `write_data` *is*
enforced - as the weaker half of a pair - and a naive enforced-somewhere check
reports a false positive on exactly the capabilities this task is about. The
check worth building is narrower: every capability that appears in `whoami` has
either an action that requires it **alone**, or a declared implication that
explains why it does not.

# Provenance

Filed from the edge testing agent's 0.11.11 pass and their 0.12.0
acknowledgement. The reframing from "wrong gate" to "misleading presentation"
was agreed with them.

**Note against my own record:** the 0.12.0 test plan told the field agent this
was already filed. It was not - this file is that filing, written after they
thanked me for it.
