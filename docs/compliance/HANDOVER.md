---
title: "lazysite - compliance handover to the operator"
subtitle: "What the project hands you, what stays ours, and what only you can produce. Read this before filling in the templates."
brand: plain
standard-margins: true
---

# Why you are reading this

You are about to run lazysite as a service. Some regulatory obligations follow
the **software** and some follow the **service**, and the split is not obvious
from either side. This document draws the line explicitly, so that neither of us
assumes the other did something.

It exists because the project's own eight-dimension review found the failure
this document prevents: the project had written an excellent set of records
about *building* lazysite, and had quietly been writing them as though they also
covered *operating* it. They do not, and could not - we do not know your CSIRT,
your named security contact, your backup schedule, or whether your alerts reach
a person.

::: widebox
**The short version.** We are the manufacturer. You are the operator. Our
evidence proves the software was built to a standard; it says nothing about your
deployment. Two documents are yours to produce, fill in and sign:
`OPERATIONS-TEMPLATE.md` and `COMPLIANCE-MAINTENANCE-TEMPLATE.md`. Everything
below is the material you need to complete them honestly.
:::

# What the project hands you

These are facts about the software, true of every deployment. Quote them
directly in your own documents.

```datatable
columns: Fact | Value | Where it is evidenced
widths: 4.4cm | 4.6cm | X
bold: 1
tone: medium
text: 3
---
Regime | Commercial | docs/POLICY.md
Licence | MIT | LICENSE, COPYRIGHT, THIRD-PARTY-NOTICES.md
Dependencies | Core Perl plus optional Template Toolkit, Archive::Zip, DB_File | dist/config/sbom-deps.json
SBOM | CycloneDX, generated per release, shipped in the tarball, under a strict gate that fails a release importing an undeclared module | dist/config/sbom-deps.json
Support period | Five years from the first stable release: to **2031-07-10**, security fixes on the stable channel | docs/POLICY.md, docs/compliance/OBLIGATIONS.md
Release channels | edge < beta < stable. A site's update_channel is the MINIMUM it accepts | ADR 0005
Vulnerability disclosure | Coordinated disclosure contact published | SECURITY.md
Threat model | STRIDE assessment and ASVS L1 baseline, current to the release you install | docs/SECURITY.md, docs/architecture/security.md
Conformity assessment | Four full eight-dimension non-functional reviews | docs/review/
Technical documentation | Annex VII index over the above | docs/compliance/TECHNICAL-FILE.md
Declaration of Conformity | Per stable release | docs/DECLARATION-OF-CONFORMITY.md
```

# What stays with the project

We remain responsible for these, and you should expect them of us:

- **Fixing defects in the software** and shipping them on the channels above,
  for the declared support period.
- **Keeping the SBOM, threat model and technical documentation current** with
  each release. These are gated at release time by
  `tools/lazysite-compliance.pl`, so a release that lets them fall behind fails
  to build.
- **Assessing significant changes** against the pentest-deferral triggers and
  recording the assessment, so the deferral stays valid
  (`docs/SECURITY.md`, `docs/adr/0007-pentest-deferral.md`).
- **Stating plainly when a release needs operator action** that a package
  upgrade does not perform. We have shipped such releases; see `UPGRADE.md`.

# What only you can produce

None of these is something we can do on your behalf, and all of them are things
an assessor will ask you for rather than us.

## 1. A service description

What the deployment is, who uses it, what data class it holds, which channel it
runs on. `OPERATIONS-TEMPLATE.md` section 1.

Note the channel choice is compliance-relevant: `stable` receives security fixes
for the support period; `edge` carries unreleased work and is not a channel to
run a service on.

## 2. Named people

A role name will not do. `OPERATIONS-TEMPLATE.md` section 2 asks for a security
triage owner, a deputy, and whoever gates deployment. If you cannot fill it in,
that is the finding - an obligation with a 24-hour clock has nobody attached.

## 3. A reporting path, rehearsed before the clock is live

If you place this service on the EU market, CRA Article 14 reporting duties are
understood to apply from **11 September 2026** - a 24-hour / 72-hour / 14-day
cascade for actively exploited vulnerabilities and severe incidents.

**Whether they apply to you, and in what role, is a determination only you and
your legal advice can make.** We are telling you the obligation exists and that
it has a date; we are not telling you it is yours.

If it is: the path must be exercised, not read about. Platform access verified
for both named people, a test submission where the platform supports one, and
the cascade walked as a tabletop - including the clock-start judgement, which is
itself rehearsable. `OPERATIONS-TEMPLATE.md` section 3.

## 4. Declared service levels, backed by a timed rehearsal

We publish a reference posture in `docs/RELIABILITY.md`. You may adopt, tighten
or loosen it - but the posture of record for your service is the one you
declare, and whatever you declare must be backed by a restore you actually
performed and timed. A backup command that exists is not an RTO.

## 5. Monitoring

We ship the mechanism: a first-party access log that measures availability, and
`lazysite check` for configuration and integrity. What to monitor, who is
alerted, and whether that alert reaches a person are properties of your
deployment. `OPERATIONS-TEMPLATE.md` section 5.

## 6. The recurring work

`COMPLIANCE-MAINTENANCE-TEMPLATE.md` and its three registers - rehearsals,
vulnerabilities, deployments.

This is the one to take seriously, because it is the one that fails silently.
Every compliance failure the project found in **its own** records was a
maintenance failure and not a declaration failure: the declarations were written
and correct, the recurring work stopped, and nothing said so. Assume the same
risk applies to you.

# How to produce your documents

1. Copy `OPERATIONS-TEMPLATE.md` and `COMPLIANCE-MAINTENANCE-TEMPLATE.md` out of
   `/usr/share/lazysite/docs/compliance/` into your own records - **not** into
   the site's document root, and not back into this project. They will contain
   identifying and operational detail about your estate.
2. Fill in the `vars:` block at the top of each. That is the only place values
   are entered; the body, the tables and the title all read back from it.
3. Build them with `md-to-pdf <file>.md`. Anything you have not filled in stays
   visible as a placeholder and warns during the build - so a half-completed
   declaration looks half-completed rather than plausible.
4. **Validate before signing.** Check that each statement is true of the running
   service rather than true of the intention: the named people know they are
   named, the reporting platform has actually been logged into, a restore has
   actually been performed and timed, and the alerts arrive somewhere a person
   reads.
5. Sign, date, and diarise the next review.

# If you operate many instances

The templates are per-deployment, and the document pipeline is built for that:
pass a data YAML after the Markdown to render one source per instance, and the
output filename follows the substituted title, so instances do not overwrite one
another. One source, one register of data, one document per site.

# References

- `docs/compliance/OPERATIONS-TEMPLATE.md` - what your deployment is.
- `docs/compliance/COMPLIANCE-MAINTENANCE-TEMPLATE.md` - what you keep doing.
- `docs/compliance/OBLIGATIONS.md` - the project's dated obligations, split
  build side from operate side. The operate rows are the ones that become yours.
- `UPGRADE.md` - per-release operator actions that a package upgrade does not
  perform.
- `docs/RELIABILITY.md` - the reference SLO/RTO/RPO posture.
- `SECURITY.md` - how to report a vulnerability to us.
