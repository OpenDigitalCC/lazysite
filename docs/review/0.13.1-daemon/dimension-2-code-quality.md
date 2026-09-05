# Dimension 2 - Code quality - the daemon service, pre-0.13.1

- Audited artefact: `main` at `53df9a44`, clean worktree
- Date: 2026-09-05
- Regime: Commercial
- Prior verdict: none - first review of this service

## Verdict

**PASS**, with two duplication findings carried as recommendations. The
mechanical gates are clean across the whole scope; the code reads as the house
writes it; where it duplicates, it duplicates something the engine already has
three of, which is a repository-wide condition the service inherited rather
than created.

## Method

`perlcritic --profile .perlcriticrc` (severity 3, the project gate) and a plain
`perlcritic -3` over every file in scope; `perltidy -st | diff` per file;
`podchecker` on the one file with POD (`lazysite-hestia-domain.pl`); a read for
the framework's duplication and idiom points.

## Findings

### F2.1 - Mechanical gates: clean (PASS)

```
perlcritic (project profile):  8 files, 0 violations
perltidy:                      8 files, 0 diffs
podchecker:                    lazysite-hestia-domain.pl pod syntax OK
```

Files: `Supervisor.pm`, `Service/Scheduler.pm`, `Jobs.pm`, `Lifecycle.pm`,
`lazysited.pl`, `daemon.pl`, `lazysite-hestia-domain.pl`,
`Manager/Sessions.pm`.

### F2.2 - Idiom and structure (PASS)

- The service registry and the job set are **barewords, not strings**: a
  coderef per service, a `\&Lazysite::Daemon::Jobs::stats_rollup` per job.
  Nothing loads code from a name that could arrive from outside, and the
  comment in `services()` says why perlcritic's stringy-require objection is
  the right one to honour here.
- Subprocesses are **list-form only** (`open '-|', $^X, $tool, @args`;
  `run_or_fail( $systemctl, 'enable', '--now', ... )`). No shell anywhere in
  scope.
- Runtime-`require`d globals are localised with `no warnings 'once'` and a
  comment explaining the warning, in both places it occurs (Supervisor,
  Jobs) - the same shape, so a reader meets it once.
- `enable_pool` became `enable_unit( $unit, $domain, $msg )` when the second
  unit arrived, rather than a second copy; `cmd_remove` iterates a table of
  `[unit, conf, what]`. The flag was added by generalising, which is the right
  direction.
- Comment density is high (Supervisor 116 comment lines in 422; Scheduler 103 in
  312). That is the house style - the comments carry the *reasons* (why
  `Restart=on-failure`, why a refusal is not a run, why `--index`) and read as
  part of the design record rather than as noise. Two of them are now WRONG
  (the restart-ceiling comment, per F1.1; "both switches must be on", per F1.2),
  which is the cost of the style: prose that asserts behaviour must move with
  the code.

### F2.3 - A fourth atomic JSON writer and a fourth `key: value` parser (WARN, carried)

`Scheduler::_write_runs` (temp + checked close + rename) is the right shape and
the fourth private implementation of it in the tree (`Auth::Settings::_write_json_atomic`,
`stats.pl::_write_json_atomic`, `Manager::Sessions::_write_revoked` do the same
by hand). `Supervisor::conf_value` is the fourth `key: value` line parser
(F1.4). Neither is wrong; each is a place the next fix has to be made four
times. The remedy is a `Lazysite::Util::write_json_atomic` and one exported
plugin-conf reader, adopted by the daemon first because it is the newest code
and has the fewest callers. Repository-wide; a filing rather than a pre-cut fix.

### F2.4 - `lazysited.pl` parses its arguments by hand (WARN, low)

A four-line index loop over `@ARGV` (`$ARGV[$i+1]` after `--docroot`) where every
other tool in `tools/` uses `Getopt::Long`. It works for the two callers that
exist (the unit and an operator), and `--docroot` given last produces a clean
"no usable docroot" refusal rather than a warning. The cost is that a third
option will be added to a loop rather than a table. Low; fold into the F1.1
branch if convenient.

## Recommendations, by impact

1. Move the two now-false comments with the F1.1/F1.2 fixes (part of that
   branch's definition of done).
2. File the shared-writer / shared-reader consolidation (F2.3) as an SM; adopt in
   the daemon when it lands.
3. `Getopt::Long` in `lazysited.pl` when the option set next changes.
