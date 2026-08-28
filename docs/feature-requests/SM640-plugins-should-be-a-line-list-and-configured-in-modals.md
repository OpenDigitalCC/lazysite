---
title: "SM640: the plugin page should list enabled plugins as lines, and every plugin's configuration should be a modal - adopted one plugin at a time"
subtitle: "Operator, 2026-08-27: 'plugin page should line list enabled plugins, and all should be managed in modals as standard practice. this can be done plugin at a time, as they are refactored to the new mechanism (like data tables)'"
brand: plain
standard-margins: true
status: partial
status-note: "PARTIAL (PENDING). THE MECHANISM SHIPPED: the page is a line list, and a plugin config opens in one shared modal that fetches its own values and no longer reloads the whole page on save. ADOPTION IS THE OPEN HALF and stays open by design - this is a standing pattern, adopted one plugin at a time. What has NOT moved into the modal: the forms plugin handler list and its add-handler wizard, which relocate DOM nodes and would be destroyed with the modal; child configs; and per-plugin action buttons, which stay on the row where they read as properties of the plugin rather than of its configuration."
---

# The shape

| Today | Proposed |
|---|---|
| every plugin's config rendered inline | a line list of enabled plugins |
| changing one re-renders all | each config is a modal that owns its own reload |
| page grows with plugins installed | page stays one screen |

# Why one at a time

A sweep touches every plugin's configuration at once - hard to verify, hard to
land, and it puts every plugin's operator in the blast radius of one change.
Adopting it as each plugin is refactored is how the data plugin arrived.
