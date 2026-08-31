---
title: "SM639: the forms plugin's configuration is rendered inline with every other plugin's, so changing one setting reloads all of them"
subtitle: "Operator, 2026-08-27: 'forms plugin, make the actual config a modal and loaded on click, so that when things change the whole plugins config doesn't need reload'"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED. The forms config opens in the shared modal and fetches on click, and saving no longer reloads the page. The handler list and the add-handler wizard were the remainder, and both filings named the same cause: showAddHandlerForm() relocated one wizard node between groups, so it could not live in a modal that is destroyed on close. Each group renders its own slot now - nothing is moved to open the form - which is the piece of work SM639 said it needed."
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
