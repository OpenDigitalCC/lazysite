---
title: "SM557: a post writes no used-only-once warnings"
subtitle: "Every form POST writes two possible-typo warnings to the error log, and the compile lint checks only the exit code."
brand: plain
standard-margins: true
status: candidate
status-note: "FOUND 2026-08-25 by the plugins structural review, PROVEN by probe tmp/plugins-probe-forms-forwarding.sh; class: operability; recommended timing: later. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. Every POST through form-handler.pl writes two lines of the form Name Lazysite::...::X used only once: possible typo to the error log, because local $Pkg::VAR is applied to packages that are only required later; t/lint/04 checks the exit code of perl -c only, so the warning passes the gate. The probe's stderr lines 1-2 carry the two warnings. The fix quietens the localisation and has the lint read the output."
---

# The finding

Every POST writes two `Name "Lazysite::...::X" used only once: possible
typo` lines to the error log: `plugins/form-handler.pl` applies `local
$Pkg::VAR` to packages that are only `require`d later. `t/lint/04`
checks the exit code of `perl -c` only, so the warning passes. The
forwarding probe's stderr lines 1-2 show the two warnings on a single
submission.

# Why it matters

Operability: two lines of noise per submission bury real errors in the
error log, and the lint that should have caught them reads only the
status.

# The proving test

`t/lint/04`: `unlike($out, qr/used only once/)`.

# Fix shape

To be designed when picked.
