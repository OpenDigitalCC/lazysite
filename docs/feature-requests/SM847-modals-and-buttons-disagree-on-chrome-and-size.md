---
title: "SM847: some modals have a header close X and others do not, and some buttons are a smaller size"
subtitle: "Release manager, 2026-09-11, on 0.13.12 in the modern style"
brand: plain
standard-margins: true
status: candidate
---

# As reported

- **Modals** - some have an X close in the header, others do not.
- **Buttons** - most are the standard size; others, such as *refresh*, *show* and
  the user *edit*, are smaller.

Recorded as reported and not yet re-measured; the report names the modern style
and the other two have not been checked.

# The shape

Both are the style guide's job: it is the component catalogue, and lint 96 holds
the stylesheets to it. A modal shell that some pages build by hand and others take
from the shared component is how one loses its close control; a smaller button is
either a deliberate secondary size the catalogue should name, or drift the
catalogue should refuse. Worth a sweep of every modal and every `mg-btn-sm`
against the catalogue rather than a fix per page.

# Related

[[SM845]] (row controls), SM640 (the one modal shell for extension config).
