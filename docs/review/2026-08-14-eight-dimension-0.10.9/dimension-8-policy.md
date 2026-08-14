# Dimension 8 - Policy compliance - lazysite 0.10.9

- Audited artefact: tag `v0.10.9` at `f8bee33`, in a clean worktree
- Date: 2026-08-14
- Regime: Commercial (CRA Article 13 manufacturer duties)
- Prior verdict: REFUSE (2026-08-14, at 0.10.8)

## Verdict

**REFUSE**, unchanged, on the same two conditions. Both require a person and
neither has had one.

What has changed is that the project can no longer ship a stable release while
pretending otherwise: `lazysite-compliance.pl --check --channel stable` blocks
on all of it, and runs first in the release gate.

## Findings

### F8.1 - The Declaration of Conformity is still unsigned and stamped 0.8.0 (REFUSE)

Unchanged. Four stable releases have now shipped against it - 0.9.4, 0.9.10,
0.10.0, and any promotion of this line. Two of those changelog entries describe
themselves as certified, which the declaration does not support.

**Now enforced.** On the stable channel:

```
FAIL declaration of conformity: stamped '0.8.0', cutting 0.10.9
FAIL declaration of conformity: unsigned
```

Advisory on edge, blocking on stable, because the declaration attaches to a
stable release. So this release was legitimately cuttable and a stable
promotion is not.

### F8.2 - CRA Article 14 still has no named owner, 28 days out (REFUSE)

The reporting duties are understood to apply from **2026-09-11**, which the
framework's own operations guide names as the live case. This review is dated
2026-08-14.

Since the last review the project has shipped the machinery an operator needs -
`OPERATIONS-TEMPLATE.md` section 3 covers the reporting path, the maintenance
template carries the rehearsal register, and the vulnerability register's
"Notified?" column is the Article 14 decision recorded at the time. The
obligations register carries the date and the compliance gate reports it at
every run.

**None of that is a named individual.** The Declaration still names a function,
"Responsible person, Open Digital CC", and no person; no filled-in operations
declaration exists for any deployment; and no reporting-path rehearsal has been
recorded. A 24-hour clock is met by someone reachable who knows the procedure.

The scope judgement - whether these duties attach here and in what role - still
needs the legal review the Declaration itself calls for.

### F8.3 - The obligations register and technical file are current (PASS, new)

Both stamped `0.10.9` and both gated:

```
ok   obligations register reviewed at 0.10.9
ok   technical file reviewed at 0.10.9
```

The support period is written absolutely as **2031-07-10** rather than "five
years from the first stable release", which decayed the moment a reader had to
work out which release that was.

### F8.4 - Supply chain (PASS, improved)

The strict SBOM gate now runs **from the tag** rather than only during a build,
closing the finding that a CRA control could not be executed by anyone auditing
the released artefact. It also earned its keep this cycle by refusing the
release over an undeclared `IO::Select` that SM294 had introduced.

### F8.5 - Still open, unchanged

| Obligation | Status |
|---|---|
| Annex VII technical file | STARTED - index form, gated |
| Signed releases (Sigstore/cosign) | OPEN - cannot be applied retroactively |
| OpenChain 5230 + 18974 policies | OPEN |
| CE marking | due 2027-12-11 |
| Vulnerability register evidencing the ADR 0007 SLAs | OPEN |

The signed-releases debt grew by one release this cycle and can never be paid
down.

## Evidence

- `docs/DECLARATION-OF-CONFORMITY.md` - version stamp and `(unsigned draft)`.
- `perl tools/lazysite-compliance.pl --check --channel stable` - 3 blocking.
- `perl tools/lazysite-compliance.pl --check --channel edge` - 0 blocking.
