---
title: "SM457: manage_forms admitted an agent to an action it never told them existed"
subtitle: "The gate said yes. The descriptor said nothing. So the agent guessed six names, none of them real, against a surface it was already entitled to use."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED (PENDING). REPORTED 2026-08-21 from a THIRD party's agent - not the field agent, a different operator on a different machine working against sovereigncomputing.org - which is what makes it worth more than one anecdote. Holding manage_forms and looking for submissions, it tried describe_capabilities, list_form_handlers, forms, form_submissions, list_submissions and submissions. Six names, NONE of them control-API actions: two are MCP tool names aimed at the wrong surface, four are snake_case guesses at a kebab-case one. The real answers are actions-list for discovery and form-submissions for the data. THE CAUSE: form-submissions is gated on [manage_forms, read_submissions] - EITHER capability admits it. read_submissions advertises it correctly. manage_forms carried NO api list at all, so a partner holding it was told about MCP tools and a WebDAV path and nothing whatever about the control API, while enforcement let them straight in. SM435 IS THIS DEFECT POINTED THE OTHER WAY - there the descriptor CLAIMED a path enforcement refused, and t/lint/68 now checks that on the WebDAV plane. Under-claiming is the quieter half: nothing 403s, nothing errors, and the agent simply cannot find a door it is holding the key to. Silence is the only symptom, so a test is the only way to see it. NEW t/lint/71 checks every capability's api list against the gate, and FOUND TWO MORE on its first run - manage_layouts and manage_themes each omitted actions gated on the pair, so a partner holding one of them was admitted to the other's and never told. All three fixed; capability-map.md regenerated. The lint FAILS rather than skips if it cannot find the action table: the first version named it %ACTIONS instead of %ACTION and skipped itself green, which is precisely the failure it exists to catch, one layer up."
---

# Six guesses, none real

```datatable
columns: Tried | What it is
widths: 7cm | X
bold: 1
tone: medium
---
`describe_capabilities` | an MCP tool, aimed at the control API
`list_form_handlers` | an MCP tool, aimed at the control API
`forms`, `form_submissions`, `list_submissions`, `submissions` | snake_case guesses at a kebab-case surface
**`actions-list`** | the real discovery action - never tried
**`form-submissions`** | the real answer - never tried
```

::: widebox
The agent held `manage_forms`. Enforcement admits `manage_forms` to
`form-submissions`. The descriptor - the only per-capability account of the
boundary readable from outside the code - listed MCP tools, a WebDAV path, and
no API actions at all.
:::

# The quieter half of SM435

SM435 was the descriptor CLAIMING a path enforcement refused: a partner
followed it and got a 403, which at least says *no*.

This is the same disagreement inverted. Nothing 403s. Nothing errors. The
agent is entitled to the action and cannot discover it, so the only symptom is
its own failure to guess - and it reads as *the feature is not there*.

That is why it needed a test rather than a fix: a silent omission produces no
event anybody can grep for.

# What the lint found on its first run

```datatable
columns: Capability | Admitted to, and never advertised
widths: 5cm | X
bold: 1
tone: medium
---
`manage_forms` | `form-submissions`, `form-list`
`manage_layouts` | `artifact-manifest`, `artifact-validate`, `preview-grant`, `theme-list`, `themes-for-layout`, `themes-list-all`
`manage_themes` | `artifact-backups-delete`, `layouts-available`, `layouts-manifest`
```

The last two are actions gated on the PAIR - either capability admits - so a
partner holding one of them was admitted to the other's actions and told
nothing. Reported by one operator, found twice more by the check.

# A note on the test itself

`t/lint/71` **fails rather than skips** when it cannot find the action table.
The first version named it `%ACTIONS` instead of `%ACTION` and skipped itself
green - "no action table found" - which is exactly the defect it exists to
catch, one layer up: a silence that reads as a pass.
