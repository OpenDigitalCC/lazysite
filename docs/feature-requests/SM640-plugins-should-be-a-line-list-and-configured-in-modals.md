---
title: "SM640: the plugin page should list enabled plugins as lines, and every plugin's configuration should be a modal - adopted one plugin at a time"
subtitle: "Operator, 2026-08-27: 'plugin page should line list enabled plugins, and all should be managed in modals as standard practice. this can be done plugin at a time, as they are refactored to the new mechanism (like data tables)'"
brand: plain
standard-margins: true
status: candidate
status-note: "RECORDED 2026-08-27 at the operator's request as the STANDING PATTERN, not as a single piece of work. Today the Plugin Config page renders every plugin's configuration inline, one after another, so the page grows with the number of plugins installed and a change to any one of them re-renders all. THE PATTERN: the page becomes a LINE LIST of enabled plugins - name, state, and a way in - and each plugin's configuration opens in a MODAL that fetches its own data and owns its own reload. ADOPTED ONE PLUGIN AT A TIME, as each is refactored to the new mechanism, rather than as a single sweep: that is how the data plugin arrived and it is the reason this is a practice rather than a project. A sweep would touch every plugin's config at once, which is the shape of change that is hard to verify and hard to land. WHY IT IS WORTH WRITING DOWN NOW, before most of the work exists: the alternative is that each plugin's config is shaped by whoever last touched it, and the page ends up with several idioms for the same act. SM639 is the first instance (forms). SM628 already proved the mechanism on the Files page's alias list, so the pattern is not speculative. NOTE ON WHERE THIS WAS FILED: the operator asked for a note in 'the plugin refactor item'. No such filing exists - SM222 covers service and plugin LIFECYCLE (start/stop/status), which is a different subject - so this is filed as its own item. If there is an intended home, this should be folded into it."
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
