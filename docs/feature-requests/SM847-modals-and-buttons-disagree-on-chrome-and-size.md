---
title: "SM847: some modals have a header close X and others do not, and some buttons are a smaller size"
subtitle: "Release manager, 2026-09-11, on 0.13.12 in the modern style"
brand: plain
standard-margins: true
status: partial
status-note: "PARTIAL 2026-09-11. MEASURED FIRST: every sheet (.mg-sheet, five of them) had a header close; no dialog (.mg-modal - the shared confirm and prompt every page uses, the style preview, the style guide's own specimen) had one. THE MODAL HALF IS BUILT: each dialog panel carries .mg-modal-close, styled as the sheet's close and in the same corner, in all three manager styles; it answers as Cancel does, so a prompt closed that way resolves null and a confirm false. t/lint/133 counts, per page, that every dialog panel and every sheet head carries its close, and names the shared dialog's wiring; seen to fail against the shared dialog as it was. THE BUTTON HALF IS A RULE TO MAKE, NOT DRIFT TO REMOVE: .mg-btn-sm is a named size in the catalogue ('Small'), used 147 times, and the catalogue shows it in row actions, table cells AND a toolbar beside a standard Add - which is exactly the mismatch reported (refresh, show, edit). Whether small is for controls inside a row or cell only, or goes, is the release manager's call; the sweep follows the rule."
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
