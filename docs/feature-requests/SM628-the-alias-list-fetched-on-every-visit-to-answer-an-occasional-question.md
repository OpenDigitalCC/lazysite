---
title: "SM628: the Files page fetched the alias list at page load and again on every folder change, to answer a question an operator asks occasionally"
subtitle: "Operator: 'Aliases not to show on every page. Probably better as modal, so it only loads on click'"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.2 (edge, 2026-08-26). FILED RETROSPECTIVELY during the 0.11.2 filing sweep, which found this ref stamped into the changelog with no filing behind it. The list is READ-ONLY and authored somewhere else entirely - a page's front matter - so nothing on the Files page acts on it, and it was on screen for every visit and re-fetched on every navigation. It opens on click now, in a modal, and fetches nothing until it does. OPENING ON DEMAND ALSO RETIRES A DEFECT RATHER THAN MAINTAINING IT: the card was folder-scoped, so it HAD to be re-fetched on navigation or it would sit there describing a folder the operator had left - the comment in loadDir said exactly that, and the re-fetch existed to patch it. A modal reads currentDir at the moment it opens, so it cannot be stale by construction. TWO SMALLER THINGS FIXED ON THE WAY: the card returned silently on a server error and left its empty state showing, so a refusal read as 'there are no aliases' - a wrong answer rather than no answer; and the empty state now names the folder it is empty FOR, since 'no aliases' and 'no aliases here' are different claims an operator cannot tell apart. t/unit/manager/126 asserts on the RENDERED html and, for the absence, on the source - a fetch that no longer happens is the one thing a render cannot show."
---

# What it cost, and what it answered

| | |
|---|---|
| Fetched | page load, plus every folder change |
| Acted on | nothing - the list is read-only, authored in front matter |
| Asked | occasionally |
