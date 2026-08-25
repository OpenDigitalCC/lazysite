---
title: "SM584: a check's result level is one vocabulary, and an unknown one is fatal"
subtitle: "Three checks reported 'ok' instead of 'OK'. The label printed empty, perl warned - and the summary counted them as neither ok, warning nor failure."
brand: plain
standard-margins: true
status: shipped
status-note: "SEEN BY THE OPERATOR 2026-08-25 in the 0.10.32 deploy log: 'Use of uninitialized value in printf at lazysite-check.pl line 1429' twice, and a status line reading '[]' for the theme-assets check. ROOT CAUSE: report() took the level verbatim; three call sites passed 'ok' where %icon and the tally both spell it 'OK'. The label printed empty and perl warned, but the real defect was quieter - the summary counts `grep { $_->{level} eq 'OK' }`, so a lowercase result was counted as neither ok, warning nor failure and vanished from both the tally and the exit code. The operator's '49 ok' undercounted by one. It became visible today because SM550 made the theme-mirror check RUN for the first time (it had been calling conf_value with one argument), so a latent mis-level surfaced the moment the check it belonged to started working. SHIPPED 0.10.33: the three sites uppercased and report() refuses an unknown level outright - a check whose answer nobody sees is worse than a check that is not there. t/tools/64 pins both the call sites and the guard."
---

# The three claims

| | |
|---|---|
| Symptom | an empty `[]` status and an uninitialized-value warning |
| Actual defect | the result was dropped from the tally and the exit code |
| Why now | SM550 made one of the three checks run for the first time |

# Proving test

`t/tools/64`: no `report()` call site passes a level outside
OK/WARN/FAIL, and the guard that refuses one is present.
