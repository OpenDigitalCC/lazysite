---
title: "SM639: the forms plugin's configuration is rendered inline with every other plugin's, so changing one setting reloads all of them"
subtitle: "Operator, 2026-08-27: 'forms plugin, make the actual config a modal and loaded on click, so that when things change the whole plugins config doesn't need reload'"
brand: plain
standard-margins: true
status: partial
status-note: "PARTIAL (PENDING). The forms plugin config form now opens in the shared modal (SM640) and fetches on click, and saving no longer reloads the page - which was the stated cost. STILL INLINE: the handler list and the add-handler wizard. showAddHandlerForm() relocates the wizard node into a handler group, so hosting that group in a modal destroyed on close would lose the node; converting it needs the wizard to stop moving DOM and is its own piece of work."
---

# What changing one setting costs today

| | |
|---|---|
| Rendered | every plugin's configuration, inline |
| Changed | one setting, in one plugin |
| Re-rendered | all of them |

The forms plugin is the heaviest of them - handlers, delivery targets and the
submissions browser - so it pays that cost most and imposes it on every other
plugin's operator.
