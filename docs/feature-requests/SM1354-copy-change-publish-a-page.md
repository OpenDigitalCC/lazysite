---
id: SM1354
title: "SM1354: copy a page, change the copy, publish it over the original"
subtitle: "A preview should be a simple workflow: the page is copied, the copy is changed (by a person, a wizard or an agent), the owner looks at it, and publishing replaces the original. Content history gives the rollback."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-06
raised-by: "release manager (SM1350 discussion)"
area: content
status-note: "Filed 2026-11-06 under SM1350. The theme copy-then-activate route is the precedent."
---

# Proposed

- **Copy:** `page-copy <page>` makes a private copy, readable only by people who may edit the page. One open copy per page. The copy renders exactly as the page would, with its layout, theme and data.
- **Change:** the copy is edited like any page (manager, MCP, wizard, agent).
- **Publish:** it replaces the original as one recorded change, with who published it and where the change came from (person, wizard, photo update, agent). A copy is not published if the original changed after it was taken; the owner is shown both.
- **Discard:** removes the copy, leaving no trace in the page's history.
- **Roll back:** the previous version of the page is restored from content history. It is offered as "Undo" right after a publish.
- **Connectors:** `copy_page`, `publish_copy` and `discard_copy` tools. `preview_page` renders a copy. An agent proposes by copying and changing; publishing needs a person unless the site allows that agent to publish.

# Questions for ruling

1. Should an agent ever be allowed to publish a copy itself, by a per-site grant?
