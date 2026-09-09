---
id: SM805
title: "SM805: the error named a value the gate rejects"
subtitle: "read_rows dies with 'pass as => \"sysop\"'. may_read admits only 'operator'. Every production caller passes 'operator', so nothing was broken - but anyone following the instruction got 'no table is declared', which is the sentence a genuinely absent table produces, so it reads as a missing table rather than an unrecognised caller."
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED 2026-09-09 on claude/sm804-a-row-source-call-is-a-connector-call. ONLY THE MESSAGE CHANGED: it names 'operator'. Found by following the instruction while writing the SM804 test - and the corrected message then caught that same test on its next run. A first version also DIED on an `as` that is neither form; t/integration/76 refused it, and rightly - see below."
---

# The two sentences

`read_rows` refuses to answer without knowing who is asking, and its die
message said:

    read_rows needs to know who is asking: pass as => "sysop" for a
    manage_data-gated surface, or as => { user, groups } for a visitor

`may_read` admits `$as eq 'operator'`, or a hashref. Not `'sysop'`.

Nothing in the engine passes `'sysop'` - every production caller passes
`'operator'` - so no shipped behaviour was wrong. What was wrong is the
instruction, and it is the only instruction a caller has.

# Why it is worth more than a typo

The failure it produces is **indistinguishable from a missing table**.
`read_rows` answers an unauthorised caller with "no table 'x' is declared" on
purpose (SM476: distinguishing "you may not read this" from "there is no such
table" tells an anonymous caller which tables a site has). So a caller who
follows the message gets a sentence that says the table does not exist, about a
table that does.

Found exactly that way, while writing the SM804 test: the message was followed,
the read failed, and twenty minutes went into looking for a missing descriptor
that was present the whole time.

# What was built

The message names `operator`. That is all, and the reason the rest was dropped
is worth more than the fix.

**The first version also died on an `as` that is neither `'operator'` nor a
hashref**, on the reasoning that a caller-shape error is a programming mistake
rather than an authorisation answer. `t/integration/76` refused it: that test
reads with `as => 'page'`, standing for a caller who is not the operator, and
expects to be **refused**. Refusing is the safer failure for a gate - and
dying on an unexpected caller would turn a refusal into a 500, which is
precisely the bug [[SM804]] had just fixed one file away.

So the strictness came out. The suite caught an over-reach that had looked
like tightening.

# Provenance

Found while building [[SM804]]. The same shape as the standing rule about a
declaration the code ignores - here the declaration is an error message, which
is the one piece of documentation a caller is guaranteed to read.
