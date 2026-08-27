---
title: "SM639: the forms plugin's configuration is rendered inline with every other plugin's, so changing one setting reloads all of them"
subtitle: "Operator, 2026-08-27: 'forms plugin, make the actual config a modal and loaded on click, so that when things change the whole plugins config doesn't need reload'"
brand: plain
standard-margins: true
status: candidate
status-note: "RECORDED 2026-08-27 at the operator's request, not built. The Plugin Config page renders every plugin's configuration inline, so a change to one costs a re-render of all of them - and the forms plugin is the heaviest, carrying handlers, delivery targets and the submissions browser. THE ASK: the forms configuration becomes a MODAL, fetched and built when it is opened, so changing a setting settles inside the modal and the page behind it is untouched. THE PATTERN IS ALREADY PROVEN HERE: SM628 did exactly this for the Files page's alias list - a card that loaded at page load and on every folder navigation became a button that fetches on click - and the same reasoning applies with more force, because this one WRITES. A modal that owns its own reload means a failed save re-renders one panel rather than discarding the operator's place on a long page. WORTH DOING ALONGSIDE SM640, which records the general form of this as standard practice; this filing is the first instance, and doing it here first is what makes the general rule credible rather than aspirational."
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
