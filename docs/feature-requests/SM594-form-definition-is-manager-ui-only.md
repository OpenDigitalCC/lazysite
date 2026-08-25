---
title: "SM594: form definition is manager-UI only, against the published channel matrix"
subtitle: "The capability matrix an operator reads says forms can be managed on the remote channels. Defining one cannot be."
brand: plain
standard-margins: true
status: candidate
status-note: "FILED BY THE SITE AGENT 2026-08-25 from the jpm-stock build, alongside SM593. The published channel matrix presents form management as available on the remote channels, while the definition of a form - the handler wiring that makes a form deliver - is reachable only from the manager UI over a cookie session. That is arguably the right design, on the same reasoning as manage_users and create_sub_users being manager-UI-only (SM268's ruling that minting credentials is a human-at-a-browser operation, which the agent agreed with when they met it): a form handler holds delivery configuration and, for SMTP and API targets, credentials. What is wrong is the MATRIX SAYING OTHERWISE, which is the same class as SM588 (the partner brief asserting a nav PUT is refused when it is accepted) and SM573 (a brief understating a grant by ten capabilities) - three in one day of a document describing engine behaviour that nothing checks. PLANNED with SM573's generator work: either the matrix is generated from the same tables the dispatchers use, or it carries the manager-UI-only exceptions explicitly. Read the agent's filing in inbox/ for the exact matrix rows they compared."
---

# The pattern this belongs to

| Document | Claimed | Actual |
|---|---|---|
| partner brief (SM588) | a nav PUT returns 403 | accepted with `manage_nav` |
| partner brief (SM573) | seven capabilities | seventeen held |
| channel matrix (this) | forms manageable remotely | definition is manager-UI only |

Each was written by hand, each describes engine behaviour, and nothing
compares any of them with the engine.

# Proving test

The matrix is generated from the capability tables, or a lint compares
its rows against them and fails on a divergence.
