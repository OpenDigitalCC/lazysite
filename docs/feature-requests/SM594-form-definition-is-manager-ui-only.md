---
title: "SM594: form definition is manager-UI only, against the published channel matrix"
subtitle: "The capability matrix an operator reads says forms can be managed on the remote channels. Defining one cannot be."
brand: plain
standard-margins: true
status: partial
status-note: "PARTIAL (PENDING). THE CONCRETE ERROR IS FIXED: manage_forms' own description still said it 'returns live submission CONTENT' after SM652 removed that reach - shipped that way in 0.11.3. SM652 updated the COMMENT above the description and left the description itself, which is the sentence a sysop reads when deciding whether to hand the grant over, overstating the reach in the direction that causes over-granting. t/unit/manager/136 now asserts the claim specifically, sabotage-verified; structural lints could not, because they compare `unlocks` against the gate and this is prose. THE GENERAL REMEDY IS NOT DONE: the published channel matrix is still hand-written and nothing compares it with the tables. That is the same class as SM588 and SM573 and needs the matrix generated from the capability tables, which is SM662's derivation work."
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
