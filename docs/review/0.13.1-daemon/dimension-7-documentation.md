# Dimension 7 - Documentation - the daemon service, pre-0.13.1

- Audited artefact: `main` at `53df9a44`, clean worktree
- Date: 2026-09-05
- Regime: Commercial
- Prior verdict: none - first review of this service

## Verdict

**WARN.** The service is documented deeply where it was designed (SM666, 713
lines, is a complete design record) and where a Hestia operator meets it (the
package README covers both switches, the cost at rest, and the provisioning
command). It is documented **nowhere else an audience looks**: the operator
guide, the developer guide, the security register, the site docs. And one
architecture statement is now false.

## Method

The five-audience taxonomy (README / FEATURES / USER / DEVELOPER / IMPLEMENTOR /
OPERATOR / SECURITY / POLICY + ADRs): `grep -rn -i 'daemon\|lazysited\|run_jobs'`
across each, then a read of what each audience would need and did not find.

## Findings

```datatable
columns: Audience | Document | Has | Lacks
widths: 2.4cm | 4.4cm | 4cm | X
bold: 1
tone: medium
text: 4
---
Everyone | docs/FEATURES.md | 0.13.0 entry: the runtime, the gate, run_jobs | the two real jobs and the --daemon flag (0.13.1 pre-cut pass)
Operator (Hestia) | debian/lazysite-hestia.README.Debian | both switches, cost at rest, --daemon command, --status vocabulary | -
Operator (general) | docs/OPERATOR.md | the FastCGI pool unit, in full | the daemon unit at all: lazysited@, the conf, --status, what the jobs write
Developer | docs/DEVELOPER.md | - | the runtime in "architecture in one screen"; how a job is added and why the set is closed
Implementor | docs/IMPLEMENTOR.md | - | that a deployment may include the runtime; the purpose-account recommendation
Sysop (site docs) | starter/docs/*.md | - | any page: the Plugin Manager description is the only sysop-facing text
Security | docs/SECURITY.md | - | a significant-change entry; a trust-boundary line for a scheduled actor without a request
Architecture | docs/architecture/performance.md | "No daemon, no process manager, no listening socket" | the sentence is no longer true as written
ADRs | docs/adr/ | 0009 (the plugin contract the daemon conforms to) | an ADR for the runtime's own decisions (one per instance; jobs are engine code; a process per service)
```

### F7.1 - The operator guide documents the pool unit and not the daemon unit (WARN)

`docs/OPERATOR.md` "Upgrading" and the FastCGI section explain
`lazysite@.service`, `/etc/lazysite/pools/`, identity, restart. The daemon has
the same shape and the same operator, and is absent. An operator not on Hestia
(the README.Debian is the Hestia package's) has nothing. The remedy is a
parallel subsection - the README.Debian section, generalised - plus a "Routine
tasks" line: what `lazysited --status` says and where the run record is.

### F7.2 - The security register has no entry for a new long-lived actor (WARN, D8 carries the policy face)

`docs/SECURITY.md` records a significant-change assessment for SM142 (the
pool: "persistent runtime, dual-mode FastCGI accept loop") and for SM294 (a
forked relay inside a privilege-dropped worker). The daemon is a persistent,
privilege-dropped process that acts on a clock with a capability-holding
identity and no request; by the register's own precedent it gets an entry. The
trust-boundaries list (1-7) should gain the scheduled actor, and F6.5's
delegation (`daemon_job_user`) belongs in it.

### F7.3 - An architecture statement is now false (WARN)

`docs/architecture/performance.md`: "No daemon, no process manager, no listening
socket owned by lazysite." The paragraph is about the *request* model, and that
model still holds - the daemon is opt-in, born disabled, and touches no request.
But the sentence as written is wrong on a site that has enabled the plugin, and
an architecture document is where a reader goes to be told the truth in one
line. Recast: the request path has none of these; SM666's runtime is a separate,
optional process that never sits in a request.

### F7.4 - The developer guide does not know the runtime exists (WARN)

"Architecture in one screen" lists the scripts; `tools/lazysited.pl` and
`lib/Lazysite/Daemon/` are not in it. A developer adding a job needs to be told:
the set is closed and why, `needs` must equal the manager's gate for the same
work (and the test that enforces it), the body contract (`ok`/`detail`/`error`),
and that the record is the operator's only view. Five sentences; they exist in
the Scheduler comments and need lifting.

### F7.5 - No ADR for the runtime's decisions (WARN)

SM666 records five architectural decisions taken 2026-09-03 with the release
manager: one daemon per instance; addressing is envelope not infrastructure; it
ships as an ADR 0009 plugin, born disabled; jobs are engine code (closed set);
one process per service, jobs as a `run_jobs` account. The framework's
correctness catalogue names "architectural drift without a corresponding ADR" as
a finding; the mirror is that architecture *without* an ADR has nothing to drift
from. ADR 0011 should be a distillation of SM666's "Decided" sections, with SM666
as its context.

### F7.6 - What is good (PASS)

- SM666 is a complete record: the decisions, the four questions and their
  answers, what phase 1 is and is not, what the tests hold, what the build
  found, the unit and the cost at rest, the survey behind the real jobs, and a
  status-note that leads with the current state.
- The Hestia README is the model operator text: two switches, what each costs,
  the one command, the status vocabulary and its remedy.
- Comments in the code carry reasons, and the tests' names are sentences.
- `plugins/daemon.pl`'s description names what a sysop is turning on.

## Recommendations, by impact

1. OPERATOR.md subsection (F7.1) and SECURITY.md entry + boundary (F7.2) - both
   before the cut; they are the two audiences who will meet the service first.
2. Recast the performance.md sentence (F7.3) - one line.
3. DEVELOPER.md paragraph and table rows (F7.4).
4. ADR 0011 (F7.5), drafted from SM666 - can follow the cut.
5. A starter/docs page for the sysop when the plugin has a second real job set to
   describe; until then the plugin description carries it.
