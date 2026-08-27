---
title: "SM652: the control API serves live submissions to `manage_forms`, MCP refuses the same grant, and the divergence is documented on the surface that does not do it"
subtitle: "Site agent, 2026-08-26, measured: the same token, in the same minute, reads submissions over one channel and is not offered the tool on the other"
brand: plain
standard-margins: true
status: candidate
status-note: "FILED FROM AN INBOX BRIEF (archived at inbox/archive/), measured by the site agent 2026-08-26. The control API accepts manage_forms OR read_submissions for both form-list and the submissions read; MCP declares read_submissions for both. Measured rather than only read: tools/list offered this grant FOUR tools - bind_form, list_form_handlers, whoami, describe_capabilities - and neither form_list nor read_form_submissions, while the control API served both to the same token in the same minute. THE DIVERGENCE IS ALREADY KNOWN AND DOCUMENTED IN THE WRONG PLACE: form_list's own description says 'Needs read_submissions (a least-privilege read; the control API also accepts manage_forms)' - so the parenthesis documents the control API's behaviour, on the surface that does not implement it, in the description of the other tool. WHAT IS NOT MEASURED, and the agent marked it: the tools/call half. A direct call to read_form_submissions under this grant was stopped by the agent's own client-side classifier before it reached the instance, so whether MCP enforces at call time as well as at listing is an INFERENCE from R-1 (which established that tools/call enforces independently for other tools), not a measurement. RELATED to SM618, which made manage_forms declare the personal data it hands over - this is the same capability, and the question of WHICH CHANNEL hands it over. Whichever decision is taken, the parity registries want a negative test with a credential holding manage_forms WITHOUT read_submissions - the credential this row already used."
---

# The disagreement

| Surface | `form-list` / `form_list` | submissions read |
|---|---|---|
| Control API | `manage_forms` **or** `read_submissions` | `manage_forms` **or** `read_submissions` |
| MCP | `read_submissions` | `read_submissions` |

Both are declared. Both registries are internally consistent. They simply
declare different answers to "who may read a form submission", and a submission
is personal data.

# Why the documentation makes it worse

`form_list`'s description reads:

> Needs `read_submissions` (a least-privilege read; the control API also accepts
> `manage_forms`)

That sentence is correct and is in the worst available place. It documents the
control API's rule, on MCP, in the description of a tool the caller was not
offered. An operator granting `manage_forms` and reading the MCP surface
concludes the capability is definition-only. The same operator reading the
control API finds it reads live submissions.

Neither conclusion is wrong about the surface they read. That is the defect: the
operator's expectation is set by whichever surface they happened to look at.

# The decision

| Option | Consequence |
|---|---|
| Narrow the control API to `read_submissions` | The channels agree; `manage_forms` becomes genuinely definition-only. Breaks any integration relying on today's rule |
| Widen MCP to match the control API | The channels agree the other way. Makes the exposure uniform and visible rather than channel-dependent |
| Keep both, document the pairing | Cheapest. `manage_forms` must then say plainly that it carries submission read, and the manager must say so at the point of granting |

The first two are the real choice. The third alone leaves the expectation set
by accident, which is the present state with better wording.

SM618 already made `manage_forms` declare the personal data it hands over. That
declaration is currently true on one channel and not the other, which is an
argument for deciding this rather than documenting around it.

# What must be true afterwards

A negative test with a credential holding `manage_forms` and **not**
`read_submissions`, on both channels, asserting the same answer. That is the
credential this finding was measured with, so it is cheap to mint again - and
without it the two registries can drift apart again silently, exactly as they
have.
