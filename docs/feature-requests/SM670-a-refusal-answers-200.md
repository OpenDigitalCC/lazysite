---
title: "SM670: the control API refuses with HTTP 200 and `ok:false`, so a client keying on the status line does not see the refusal"
subtitle: "Site agent, 2026-08-28, while proving the SM652 submissions split from outside: 'a status-code-keying client misses them'"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-11 (0.13.13), to the release manager's ruling that day. A control-API refusal answers with an HTTP status from its kind - forbidden/not-yours/permission/blocked/disabled 403, not-found/unknown-domain 404 (an unknown action is given kind not-found), exists/in-use/confirm 409, too-large 413, rate 429, render/snapshot/CGI-output failures 500, partial 207 - and any other kind, or none, 400. ok:false stays in every body. No deprecation step: pre-stable, the release manager's standing preference is to break compatibility rather than carry the old register. The status lives in one table (Lazysite::Manager::Common::%REFUSAL_STATUS) read by the one writer, respond(). t/unit/manager/186, reproduced first. The manager's own pages parse the body whatever the status, so they are unaffected; MCP tool results are JSON-RPC and stay 200."
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

# Ruled and built (2026-09-11)

The release manager ruled the two cases the filing called awkward: **a refusal
with no kind answers 400**, and **`partial` answers 207** - part of the write
happened, so it is neither a success a status-keying client would pass over nor
a 4xx that invites retrying a half-applied write. And the deprecation path above
was not taken: before stable, breaking a client beats carrying two registers
that disagree. The body keeps `ok:false` permanently, as this filing asked.

The map is one table beside the one writer (`%REFUSAL_STATUS` and
`respond()` in `Lazysite::Manager::Common`); a kind nobody mapped falls to 400
rather than to 200. The unknown-action refusal had no kind and now carries
`not-found`, so it answers 404 - which also makes [[SM237]]'s distinction
visible without parsing. The manager's pages were surveyed first: every one
parses the JSON body whatever the status (a `fetch` resolves on 4xx), so none
changes behaviour.
