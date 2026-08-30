---
title: "SM652: the control API serves live submissions to `manage_forms`, MCP refuses the same grant, and the divergence is documented on the surface that does not do it"
subtitle: "Site agent, 2026-08-26, measured: the same token, in the same minute, reads submissions over one channel and is not offered the tool on the other"
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED. The release manager chose to NARROW THE CONTROL API, so form-submissions and form-list require read_submissions on both channels and manage_forms is genuinely definition-only. Narrowed in BOTH tables - %need for token clients and %COOKIE_CAP for cookie sessions - so a delegate holding manage_forms loses the submissions view in the manager too; a real operator bypasses the capability gate and is unaffected. form-list is included because it returns row_count - whether a form has submissions and how many - which is a read of submission EXISTENCE even without content, and MCP has always treated it that way. THE STALE SENTENCE WAS CAUGHT BY THE TEST, not by reading: form_list's description said \"the control API also accepts manage_forms\", which documented the divergence on the surface that did not implement it - and with the rule gone it would have told an agent the opposite of what both channels now do. Corrected. WHAT THIS EXPOSED AND DID NOT CHANGE: form-submission-delete, form-submission-confirm and form-submissions-delete-bulk are still gated on manage_forms alone - so that capability can DELETE a submission it may not READ. That is incoherent with \"definition-only\" and is left alone deliberately: they are destructive operations on personal data and re-gating them is a larger decision than this filing took. Recorded as SM660. BREAKING: any integration holding only manage_forms loses both reads, which wants naming in the release notes."
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
