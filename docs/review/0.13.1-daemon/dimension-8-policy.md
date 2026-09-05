# Dimension 8 - Policy compliance - the daemon service, pre-0.13.1

- Audited artefact: `main` at `53df9a44`, clean worktree
- Date: 2026-09-05
- Regime: Commercial
- Prior verdict: none for this service; the repository's D8 was REFUSE at 0.10.9
  (unsigned declaration), unchanged by anything here

## Verdict

**WARN**, scoped. Within the service the policies that bind are met - ADR 0009
conformance, the SBOM gate, the release doctrine - and one obligation the
project set for itself is not: a significant-change assessment for a change
that, by the project's precedent, triggers one. The repository-level REFUSE
(the unsigned Declaration of Conformity, OBLIGATIONS.md row 1) is out of this
review's scope and unchanged.

## Method

Read `docs/POLICY.md`, `docs/compliance/OBLIGATIONS.md`, `docs/adr/0007` (the
significant-change triggers), `docs/adr/0009`, `docs/compliance/TECHNICAL-FILE.md`,
against what the service adds. Checked the packaging (the 0.13.0 deb's contents
and control archive) for what an installed host receives.

## Findings

### F8.1 - Significant-change assessment: expected by precedent, absent (WARN)

ADR 0007's triggers are `new-external-interface`, `new-authentication-method`,
`new-dependency-with-authentication-logic`, `new-processing-of-restricted-data`.
Read literally, phase 1 fires none cleanly - no interface, no auth, no
dependency; the sessions sweep is new *processing* of the session registry (IP
and UA) by a new actor, which is the closest. Read by precedent, the register
has entries for SM142 (a persistent worker) and SM294 (a forked path inside
one), each described as a new execution model, and OBLIGATIONS.md row 2 promises
an entry "per triggering release". A privilege-dropped process acting without a
request is a bigger change to the execution model than either. The assessment
is a page, and D7 F7.2 says what goes in it.

### F8.2 - ADR 0009 conformance (PASS)

`contract => 1`; `owns.config_keys` are the three keys the config schema
declares; `owns.storage` is `lazysite/daemon/` (so a backup and a site package
carry the run record); `owns.endpoints` is empty and says why; `owns.capabilities`
is `run_jobs`, and `t/lint/76` proves every capability is core or plugin-owned -
it is the lint whose list-context defect this plugin's pretty-printed
`--describe` surfaced and fixed. Disabled means the process never starts, which
is stronger than the ADR's own "executes nothing".

### F8.3 - SBOM and manifest (PASS)

`Jobs.pm` and `Lifecycle.pm` add no dependency; `tools/manifest-to-sbom.pl
--strict` is a release gate and passed for 0.13.0. The classification file
declares both new `lib/Lazysite/Daemon` install dirs (the first 0.13.0 cut
failed precisely because one was missing, which is the gate doing its job).

### F8.4 - Packaging: the unit ships, nothing reloads systemd on upgrade (WARN, build-side)

`dpkg-deb -c lazysite-common_0.13.0-1_all.deb` shows
`usr/lib/systemd/system/lazysited@.service` and `lazysite@.service`; the control
archive holds **no postinst** at all. So an upgrade that changes either unit file
leaves running instances on the old definition until an operator runs
`systemctl daemon-reload` by hand, and nothing tells them to. The cause is not
established here (compat 13 with units installed by `.install` into
`usr/lib/systemd/system` - `dh_installsystemd` may be skipping template units,
or the path); the *absence* is the finding. Pre-existing for the pool unit; the
daemon doubles its reach. Verify with a real package upgrade before deciding the
remedy (a `dh_installsystemd --name` override, or a two-line postinst).

### F8.5 - Obligations anchors are stale, generally (note, out of scope)

OBLIGATIONS.md rows 2 and 3 are anchored at "0.10.9 done"; the threat model
row says "current with the architecture" as of 2026-08-14. Three minor lines
later, with F7.3's false sentence in the architecture docs, those anchors need
moving whatever this review decides. Repository-level; recorded for the next
full review.

### F8.6 - Data protection (PASS, note)

The sessions sweep deletes expired rows carrying IP and user agent on a clock
rather than on a login. That is a retention rule finally applied
unconditionally - the direction data-protection policy wants - and the run
record states counts, not contents. The lazysite-check personal-data note for
`sessions.jsonl` remains accurate.

## Recommendations, by impact

1. Write the significant-change entry (F8.1) with D7 F7.2's content; move the
   OBLIGATIONS row 2 anchor to 0.13.1 when it lands.
2. Establish why the deb has no postinst (F8.4) on a test host, then fix it for
   both units.
3. Carry F8.5 to the next repository-level review.
