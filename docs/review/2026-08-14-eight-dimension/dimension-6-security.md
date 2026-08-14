# Dimension 6 - Security - lazysite eight-dimension review

- Audited tree: `main` at `v0.10.8` (`ec6fe0a`)
- Date: 2026-08-14
- Regime: Commercial
- Prior verdict: REFUSE, cleared in-cut (2026-07-18)

## Verdict

**REFUSE**. Three conditions, in descending order of seriousness:

1. A defect live in the released 0.10.8 edge build leaves content **stored as
   protected and still served** (F6.1 - the same defect as D1 F1.1, assessed
   here for its security consequence rather than its cause).
2. The **significant-change register has gone stale again** (F6.2), and it went
   stale over precisely the changes that fire its own triggers: content moved
   out of the document root, and a new external interface. This is the second
   consecutive review to raise the register.
3. The **threat model of record does not describe the current architecture**
   (F6.3). `docs/SECURITY.md` and `docs/architecture/security.md` contain no
   mention of the private store or the front door - the two structural changes
   that alter how protected content is stored and how requests are routed.

The pentest gate remains properly declared with a dated, auditable waiver (ADR
0007) and has not expired. The supply-chain controls are the right mechanisms,
but the strict SBOM gate could not be run from the audited tag at all (F6.6).

This is a harsher verdict than the period's engineering deserves, and that
should be said plainly: the 0.10.x line is the strongest sustained security work
in the project's history. The refusal is about the *record* of that work keeping
pace with it, plus one live bug.

## Method

- Verified the 2026-07-18 refusal conditions as cleared or open.
- Read the significant-change register against the release history and against
  ADR 0007's own trigger list.
- Checked the STRIDE/ASVS documents against the architecture they claim to
  describe.
- Ran the SBOM strict gate and the secrets lint.
- Checked the SM283 disclosure's real-world closure state, not just its filing
  status.

## Findings

### F6.1 - Protected content is served after a crashed protect call (REFUSE)

Full mechanism at D1 F1.1. The security consequence, stated separately because
it is what makes this a refusal rather than a bug report:

- the rule is stored and `acl-get` returns it, so every surface *reports* the
  content as protected;
- pages answer 302 to an anonymous request, which looks like working gating;
- **static files answer 200, byte-identical to the source**;
- the call never reaches the audit write, so the trail and the stored ACL
  disagree about whether anyone protected that content.

An operator inspecting this site through any interface lazysite offers is told
the content is protected. It is not. That combination - a false negative in the
audit trail and a false positive in the permission read - is worse than an
outright failure, and it is the shape SM283 was.

Fix written and tested on `claude/sm296-acl-set-crash`; not in the audited tree.

### F6.2 - The significant-change register is stale, over its own triggers (REFUSE)

ADR 0007 defers the first pentest engagement on the condition that the gate
"fires ahead of schedule on significant change unless a recorded assessment
finds the change contained", with these triggers:

```yaml
significant-change-triggers:
  - new-external-interface
  - new-authentication-method
  - new-dependency-with-authentication-logic
  - new-processing-of-restricted-data
```

The register's last entry is **2026-08-11 (SM279)**. Since that entry, 0.10.7
and 0.10.8 shipped the SM285-SM293 programme, which fires at least two triggers:

- **new-processing-of-restricted-data** - SM286 moves protected content out of
  the document root entirely, into `<docroot>-lazysite-private`. Where
  restricted content physically lives, and which identity may create and write
  that directory, changed.
- **new-external-interface** - SM293 step 5 ships `lazysite-front.pl`, a new CGI
  surface that a front end is pointed at and that makes every routing decision
  for the site.

Neither has a register entry. The waiver's integrity depends on this register
being kept, because the register is the thing standing in for an engagement that
has not happened. A deferral whose conditions are not being recorded is not a
deferral.

This is the second consecutive review to raise it: F6.2 in the 2026-07-18 review
was "significant-change register stale", closed in-cut. It went stale again
within four weeks, which suggests the register needs to be part of the release
checklist rather than a review artefact.

### F6.3 - The threat model of record predates the architecture (REFUSE)

```
$ grep -c "private store\|lazysite-private" docs/SECURITY.md docs/architecture/security.md
docs/SECURITY.md:0
docs/architecture/security.md:0
$ grep -c "FrontDoor\|front door" docs/SECURITY.md docs/architecture/security.md
docs/SECURITY.md:0
docs/architecture/security.md:0
```

`docs/architecture/access-control-model.md` (SM290) does describe both, and is
pinned to the code by `t/lint/36`. So the knowledge exists and is enforced - but
it is not in the documents that `docs/POLICY.md` and the Declaration of
Conformity point at as the security model of record, and a Commercial regime
requires a current STRIDE/ASVS model for a user-facing service.

The gap is not cosmetic. The private store changes the answer to "where does
restricted data live and who can read it", and the front door changes the answer
to "what decides whether a request reaches the engine" - the two questions the
threat model is for.

### F6.4 - SM283's mitigation is shipped but not deployed where it was disclosed (WARN)

SM283 was a live disclosure: gated static files served anonymously by the front
end, across a fleet, for weeks. The code remedy shipped (the Hestia proxy
templates, the `X-Lazysite-Front` observable, `t/lint/33`, `t/integration/42`).

The filing itself is explicit that this is **not delivered by a package
upgrade** - the template must be installed and each domain moved onto it. Probed
from outside on 2026-08-14, `edge.explore.lazysite.io` - confirmed running
0.10.8 by fingerprint - returns **no `X-Lazysite-Front` header**, so the proxy
template is not installed on that domain.

That is an operator step rather than a code defect, and the project built the
observable precisely so it could be checked without credentials. But a
mitigation for a live disclosure that is not deployed on the disclosing host is
an open exposure, and it should be tracked as one until a fleet sweep says
otherwise. Recorded as task #204; the fleet-wide check (#196) has also not been
run.

### F6.5 - What passes (PASS, noted)

- **The pentest waiver is intact and unexpired**: ADR 0007, signed and dated
  2026-07-10, expiry the first third-party engagement or 2026-12-31, whichever
  first. That expiry is now four and a half months away and should be on the
  release manager's calendar.
- **SBOM strict gate**: the design is right - the SBOM cannot drift from the
  code, because a release fails if the code imports an undeclared module. But
  it **could not be executed on the audited tree**; see F6.6.
- **The in-app trust gate** (SM293 step 4, `t/lint/38`) converts a front-end
  configuration requirement into an enforced application control. This is the
  right direction and directly addresses the root cause behind SM248, SM268 H17
  and SM283.
- **`lazysite check --check-acl`** lets a site prove its own gating from
  outside, with public controls of the same file type - so a refusal that
  happens because the front end cannot read the file is distinguishable from a
  refusal that is the ACL working.

### F6.6 - The SBOM gate cannot be run from the tag it attests (WARN, new)

An earlier draft of this report listed the strict SBOM gate as passing. It was
then run, and it does not:

```
$ perl tools/manifest-to-sbom.pl --strict
Cannot read /srv/projects/lazysite-audit/release-manifest.json: No such file or directory
sbom rc=2
```

Same root cause as D3 F3.1: `release-manifest.json` is a **gitignored build
artefact**. It exists in a developer's working copy after a build, and does not
exist in a clean checkout of `v0.10.8`.

For D3 this was a test-reproducibility problem. Here it is a compliance one, and
sharper. The SBOM is a CRA Article 13 obligation, and the strict gate is the
control the project relies on to keep it honest - `docs/POLICY.md` cites it as
the reason the SBOM "cannot drift from the code". That claim is true during a
release build and **unverifiable afterwards**: an auditor, a downstream
consumer, or a future maintainer who checks out the tag cannot run the control
that substantiates it.

This does not mean the SBOM is wrong. It means the gate's result is not
reproducible from the artefact of record, which for a compliance control is the
property that matters. Making `install.pl` and the SBOM tool generate the
manifest when it is absent (it is derivable from the tree) fixes D3 F3.1 and
this finding together.

## Evidence

- `lib/Lazysite/Private.pm:223`, `:261`.
- `docs/SECURITY.md:72-105` - the register and its last entries.
- `docs/adr/0007-pentest-deferral.md:26-56` - triggers and waiver expiry.
- `curl -sI https://edge.explore.lazysite.io/` - no `X-Lazysite-Front`.
- `tools/manifest-to-sbom.pl --strict` on a clean worktree - `rc=2`, cannot read `release-manifest.json`.
