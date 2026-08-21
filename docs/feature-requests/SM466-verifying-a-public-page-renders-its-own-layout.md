---
title: "SM466: no supported way to verify that a public page renders its own layout"
subtitle: "SM441 fixed previews that rendered a domain's page in the base theme. Confirming that fix on a live site means fetching the page as a visitor - and a partner agent's own tooling is the thing that cannot do it."
brand: plain
standard-margins: true
status: candidate
status-note: "FILED 2026-08-21 from the field, and it is a TOOLING gap rather than an engine defect. THE SHAPE: SM441 was a real fault - both page-scope previews shelled the processor without HTTP_HOST, so a domain's page rendered with the BASE layout, theme and nav. The fix is in and tested. But the field cannot CONFIRM it on a live multi-domain instance, because confirming it means asking 'what does a visitor to this host actually receive' and every tool a partner grant carries answers a different question: preview_page renders through the manager, read_page returns source, page_status reports metadata. Each is a statement about the instance's view of the page, not about what the host serves. RELATED TO SM456, and worth reading together: that filing is about the field agent's own tooling blocking verifications the grant permits. This is the specific case that keeps recurring, because per-Host routing means the LAYOUT is exactly the thing a docroot-shaped tool cannot see. WHY 'JUST CURL IT' IS NOT THE ANSWER, though it works: it is unauthenticated egress from an agent session, it is outside the grant model entirely, and a result obtained that way cannot be attributed to any capability - so it proves the page renders and proves nothing about what the grant can establish. A GRANT CANNOT ATTRIBUTE ITS OWN ACCESS: a check that succeeds tells you the union of everything the caller holds worked, not which capability made it work. WHAT WOULD CLOSE IT, for the release manager to weigh: a preview_domain-shaped answer for a PAGE - render as a visitor to host H would receive it, returning enough of the head to identify the layout and theme actually used. domain-check is the precedent: it already answers a question about what the outside world sees, from inside, over the API."
---

# The question and the tools

```datatable
columns: Tool | Answers
widths: 4cm | X
bold: 1
tone: medium
---
`preview_page` | what the manager renders for an operator
`read_page` | the source, before any layout is chosen
`page_status` | the instance's metadata about the page
**wanted** | **what a visitor to this host receives**
```

Per-Host routing is what makes these different answers rather than three views
of one answer. The layout is chosen from the Host, so a tool that does not
carry a Host cannot report the layout -- and that is the exact thing SM441
broke and the exact thing the field wants to confirm.

# Why this is filed rather than worked around

Fetching the page directly does work. It is also unauthenticated egress
outside the grant model, and a result obtained that way cannot be attributed
to any capability the partner holds -- so it settles whether the page renders
and settles nothing about whether the grant can establish it.
