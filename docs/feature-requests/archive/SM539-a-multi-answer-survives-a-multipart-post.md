---
title: "SM539: a multi-answer survives a multipart post"
subtitle: "A form with an upload keeps only the last value of a repeated key, so checkbox groups lose their ticks."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): both branches of parse_post add fields through one _field_add, which accumulates a repeated key as `a; b` exactly as the urlencoded path did since SM401; the multipart branch's overwriting assignment is gone. Proving test t/unit/forms/10-a-multi-answer-survives-a-multipart-post.t posts the same repeated key urlencoded and multipart (beside a real file part) through the real handler and asserts both stored rows read `red; blue`; t/unit/forms/06's source pin moved to the shared helper and now asserts both branches use it. FOUND 2026-08-25 by the plugins structural review, PROVEN by probe tmp/plugins-probe-forms-multipart-multi.pl; class: correctness; recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. A repeated key survives a urlencoded POST (colour=red; blue, SM401) but a multipart POST keeps only the last value (colour=blue): the accumulation at form-handler.pl 943-950 lives only in the urlencoded branch of parse_post and line 926 overwrites. Any form with an upload and a checkbox group loses ticks. The fix shares the accumulation between both branches."
---

# The finding

A repeated key survives a urlencoded POST (`colour=red; blue`, the SM401
behaviour) but a multipart POST keeps only the last value
(`colour=blue`). The accumulation at `plugins/form-handler.pl 943-950`
exists only in the urlencoded branch of `parse_post`; the multipart
branch at `plugins/form-handler.pl 926` overwrites. Any form with an
upload and a checkbox group loses ticks.

# Why it matters

Correctness: the stored row differs from what the visitor submitted, and
the difference depends on whether the form happens to carry a file
field. Two forms with the same checkbox group record different answers.

# The proving test

NEW `t/unit/forms/10-a-multi-answer-survives-a-multipart-post.t` with
`is($row->{colour}, 'red; blue')`.

# Fix shape

Move the repeated-key accumulation out of the urlencoded branch so both
branches of `parse_post` feed the same join, and the multipart path
appends rather than overwrites at 926.
