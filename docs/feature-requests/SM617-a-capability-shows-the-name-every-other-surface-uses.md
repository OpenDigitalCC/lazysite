---
title: "SM617: the Groups grid showed human labels while every other surface named the same capability in code"
subtitle: "Operator request, 2026-08-26: expose each capability's technical name on hover. The mapping between what the grid shows and what the rest of the system says had been left to inference"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.0 (stable, 2026-08-26), commit ae0ff2fb, alongside SM616. FILED RETROSPECTIVELY 2026-08-26 during the 0.11.0 filing sweep, which found this ref stamped into the changelog with no filing behind it. THE ASYMMETRY: the Groups page is where an operator DECIDES what a partner holds, and it was the one surface that did not use the system's own vocabulary for it. `whoami` answers `manage_content`. The capability map, the docs, `describe-capabilities` and a partner's refusal message all name it in code. The grid showed a human label and nothing else, so an operator reading a refusal that named `manage_forms` had to work out which checkbox that was. `title=` on the capability row label, escaped through the page's own `escHtml`. NOT A DEFECT in behaviour and filed anyway, because the register of what changed is the record and a changelog ref with no filing behind it is a hole in it - which is how this one was found."
---

# One capability, four names for it

| Surface | What it says |
|---|---|
| `whoami` | `manage_content` |
| `describe-capabilities` | `manage_content` |
| a refusal message | `manage_content` |
| the Groups grid | a human label, and no way back |

The grid is where the decision is made. It was the only one not speaking the
system's own vocabulary.
