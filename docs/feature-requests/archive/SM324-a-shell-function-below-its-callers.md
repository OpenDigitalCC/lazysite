---
title: "SM324 - the re-apply sweep has been sweeping the sites it was written to skip"
subtitle: "in_list was defined below three callers. Bash resolves at call time, so the guard was `command not found` - which returns 127, so `&& continue` never continued."
brand: plain
status: shipped
status-note: "SHIPPED in 0.10.11. in_list hoisted above every caller, and t/lint/50 holds the class - every shell function defined above its callers, shown to catch all three shipped call sites. Found by the operator on their first 0.10.10 rollout, because the SM317 probe added the first UNCONDITIONAL caller; the other two sit behind --reapply-acls and had been latent for months. FILED 2026-08-16."
---

# What was wrong

`installers/hestia/lazysite-hestia-update-all.sh` defined `in_list` near the
bottom, below three call sites. Bash resolves a function at CALL time, so those
calls were `command not found` - and that returns **127**, so the idiom

```bash
in_list "$d" "${SKIPPED[@]}" && continue
in_list "$d" "${FAILED[@]}"  && continue
```

never continued.

# What it cost

`--reapply-acls` has been sweeping sites it was written to exclude: ones held
back by their update channel - still on an old version, where the private store
may not exist at all - and ones that **failed** to upgrade. The script's own
comment states why they must be excluded:

> Runs only on sites that ACTUALLY UPGRADED: a site skipped by its update channel
> is still on its old version, where the private store may not exist at all, and
> sweeping it would be meaningless at best.

# Why it surfaced when it did

The two original callers live behind `--reapply-acls`, so the fault only ran when
an operator opted into the sweep. SM317's ACL probe added the first
**unconditional** caller, and the operator met it on their first rollout of
0.10.10 as two `command not found` lines.

That is the signature of a defect class worth mechanising: silent,
order-dependent, and invisible until something unrelated moves. Perl has no such
problem - subs resolve at runtime from a package table - which is exactly why
nobody looks for it in the shell scripts.

# Related

SM317 (the change that exposed it), `t/lint/50` (the class check), SM286 and
SM296 (the sweep whose guards these are).
