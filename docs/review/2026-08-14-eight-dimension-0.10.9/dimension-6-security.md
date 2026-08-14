# Dimension 6 - Security - lazysite 0.10.9

- Audited artefact: tag `v0.10.9` at `f8bee33`, in a clean worktree
- Date: 2026-08-14
- Regime: Commercial
- Prior verdict: REFUSE (2026-08-14, at 0.10.8)

## Verdict

**WARN**. All three refusal conditions are closed and verified. One WARN-level
finding remains open and is now confirmed open **on the deployed host** rather
than inferred: SM283's remedy has still not been installed on the domain the
disclosure came through.

## Findings

### F6.1 - Content served after a crashed protect call: CLOSED

Fixed at source (D1 F1.1) with a regression test. The state it produced - a
stored rule, pages gating, static files serving, and no audit line - is no
longer reachable through that path.

### F6.2 - Significant-change register: CLOSED and mechanised

The register carries a 0.10.9 entry assessing SM294's forked relay: accepted, on
the grounds that it is a fork inside an existing trust boundary, bounded by a
timeout, adding no new identity, capability or external interface. The verdict
records the reasoning rather than asserting the conclusion.

More importantly the recurrence is now gated: `lazysite-compliance.pl` checks
the register references the version being cut. The previous review noted this
was the second consecutive review to find it stale; there will not be a third
without a build failing first.

### F6.3 - Threat model current: CLOSED

`docs/architecture/security.md` gains "Content outside the served tree (SM286)"
and "The front door (SM293)", and its three-layer model no longer claims the
web-server layer is where lazysite cannot enforce policy. `docs/SECURITY.md`
gains two trust boundaries - the served-tree boundary, now a filesystem boundary
rather than only a decision one, and the front door - plus revised STRIDE rows.

`t/lint/45` closes the adjacent defect that ADR 0008 froze two front-matter
fields that did not exist.

### F6.4 - SM283's remedy is still not deployed (WARN, carried and now MEASURED)

The one finding that did not move, and the only one verifiable only from
outside.

After the 0.10.9 upgrade, on the host the disclosure came through:

```
$ curl -sI https://edge.explore.lazysite.io/
  (no X-Lazysite-Front header)
```

The Hestia nginx proxy template is a **template assignment**, not package
payload - no upgrade installs it. The rollout used `--rebuild --reapply-acls`
and not `--proxy`, so the domains were not moved onto it.

What this does and does not mean at 0.10.9 is worth stating precisely, because
the structural work has changed the exposure:

- protected **content** is no longer in the served tree once its rule has been
  applied on 0.10.8+, so a stock proxy has nothing protected to serve;
- but the **engine tree** is still under the document root unless
  `migrate-engine-tree` has been run, and a stock proxy serving `gz` by
  extension would serve `lazysite/backups/*.tar.gz` - a pre-install snapshot
  including the account store.

So the operate-side remedy is either `--proxy`, or `migrate-engine-tree --all
--apply` plus the re-apply sweep. Tracked as tasks #204 and #196; the fleet-wide
check has still not been run.

### F6.5 - The SBOM gate can now be run from the tag it attests: CLOSED

Previously the strict gate needed a gitignored build artefact, so the CRA
control that substantiates the SBOM claim could not be executed by anyone
auditing the released tag. It now runs from a clean worktree, rc 0.

### F6.6 - The pentest waiver holds, and its expiry is closer (WARN)

ADR 0007's deferral remains intact and its conditions are now being kept - the
register is current and gated. Expiry is 2026-12-31 or first GA marketing.
Procurement lead time for a qualified third-party engagement is not short, and
this is now the third review to say so.

## Evidence

- `curl -sI https://edge.explore.lazysite.io/` - no `X-Lazysite-Front`.
- `docs/SECURITY.md` - register entry dated 2026-08-14 naming 0.10.9.
- `perl tools/manifest-to-sbom.pl --strict` from a clean worktree - rc 0.
