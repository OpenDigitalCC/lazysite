---
title: "SM670: the control API refuses with HTTP 200 and `ok:false`, so a client keying on the status line does not see the refusal"
subtitle: "Site agent, 2026-08-28, while proving the SM652 submissions split from outside: 'a status-code-keying client misses them'"
brand: plain
standard-margins: true
status: candidate
---

# What was observed

Proving the submissions split with a grant holding `manage_forms` and NOT
`read_submissions`, the control API refused `form-list` and `form-submissions`
correctly - with the right message, naming the action, pointing at
`describe-capabilities`. And it returned **HTTP 200**, carrying `ok:false` in
the body.

Every refusal on this surface does. The JSON is unambiguous; the status line
says the request succeeded.

# Why it is worth a number

A capability refusal is the case a client most needs to distinguish, and the
status line is the first thing most HTTP clients look at. A caller that checks
`r.ok` before parsing - the idiomatic shape in every language - sees success,
parses a body that is not what it expected, and reports something else: a
missing field, a null, a parse error. The refusal is legible only to a reader
who already knows to look past the status.

It is the same shape as SM662 and SM647: a surface answering consistently in one
register and not in another, so a caller consulting the wrong one is told
something untrue. It is not an access hole - enforcement is correct, which is
exactly why it survives review.

# Why it is NOT being changed in 0.11.4

Every existing client keys on `ok`, because that is what this API has always
done and what its documentation describes. Moving refusals to 4xx mid-release
would break each of them silently and simultaneously, which is worse than the
inconsistency being fixed - and worse in the way that is hardest to notice,
since a client that stops seeing refusals looks like a client with nothing to
refuse.

This needs a deprecation path, not a patch:

1. Decide the status for each refusal kind - `forbidden` is 403, `invalid` is
   400, and `partial` (SM650) is genuinely awkward, since the write half
   succeeded.
2. Announce it, with `ok:false` still present in the body throughout, so a
   client can be corrected before the status changes rather than after.
3. Change the status, keeping the body identical, so a corrected client sees
   both and an uncorrected one sees what it always saw until the release that
   moves it.

The body must keep `ok:false` permanently either way. Two registers agreeing is
the goal; replacing one with the other just moves which clients break.

# Related

[[SM662]] (one capability described in six places - the same failure, in the
declaration rather than the response), [[SM650]] (`kind: "partial"`, the refusal
shape with no obvious status), [[SM237]] (telling "you may not" from "no such
action", which this would make visible without parsing).

# Not started
