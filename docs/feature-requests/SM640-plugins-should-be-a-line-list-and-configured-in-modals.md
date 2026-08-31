---
title: "SM640: the plugin page should list enabled plugins as lines, and every plugin's configuration should be a modal - adopted one plugin at a time"
subtitle: "Operator, 2026-08-27: 'plugin page should line list enabled plugins, and all should be managed in modals as standard practice. this can be done plugin at a time, as they are refactored to the new mechanism (like data tables)'"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED. The mechanism shipped earlier - the page is a line list and a plugin config opens in one shared modal that fetches its own values and no longer reloads the page. THE BLOCKER ON THE REST IS GONE: the handler section stayed out of the modal because showAddHandlerForm() MOVED a single wizard node into whichever group was being added to, and a modal destroyed on close takes a moved node with it. Each group owns its slot now, rendered in place, so nothing moves and t/lint/106 holds that property rather than the markup. Per-plugin ACTION buttons stay on the row by design - they read as properties of the plugin rather than of its configuration - and they are one aligned group there now rather than three baselines."
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
