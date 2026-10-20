---
id: SM1199
title: "SM1199: the precheck's job count is settable"
subtitle: "tools/precheck.sh ran prove at -j8 whatever the host; LAZYSITE_PROVE_JOBS or --jobs now sets it, and 8 stays the default."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-19
raised-by: the C2 restack (release manager's agent), 2026-10-19
area: tools
status-note: "SHIPPED (0.15.13) on n690: tools/precheck.sh (--jobs, LAZYSITE_PROVE_JOBS); t/tools/187."
---

# What happened

The C2 restack found that `tools/precheck.sh` ran `prove -l -j8` with the 8
written into the line. The shared-host rule (release manager, 2026-10-17) is that
an agent runs tests at `-j2` at most, and there was no way to keep it short of
editing the tool.

# What shipped

- `tools/precheck.sh [--jobs N] [BASE]`, or `LAZYSITE_PROVE_JOBS=N`. The flag
  wins over the variable. With neither, the run is `-j8` as before, so the release
  manager's runs and the integration are unchanged. A value that is not a positive
  whole number stops the tool with exit 2 and names the value; nothing is run.
- Agents on the shared host run `nice -n 19 ionice -c3 bash tools/precheck.sh --jobs 2 BASE`
  (or export `LAZYSITE_PROVE_JOBS=2`).
- The other tools were read, and left alone:
  - `tools/suite.sh` runs `prove -lr -j$JOBS` with `JOBS=$(nproc)`, one run at a
    time under its lock, started by the release manager (and the nightly), not by
    agents.
  - `tools/integration.pl` runs `prove -l FILE` per test, with no `-j`, and
    prechecks each stack through `tools/precheck.sh`, so it keeps the default.
  - `tools/gate-main.sh` and `tools/overnight.sh` hard-code no `-j` and run no
    `prove` of their own (they go through suite.sh and the integration).
  - `tools/handoff.sh` calls `tools/precheck.sh`, so it takes the variable
    through the environment.
- `t/tools/187` runs the real script with a stub `prove` first on the PATH and
  asserts the argument it receives: `-j8` by default, `-j2` from the variable and
  from the flag, the flag over the variable, and a refusal of a non-number.
