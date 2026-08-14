---
title: "Operations declaration - {{operator_legal_name}}"
subtitle: "Per-instance operations record for {{service_name}}, running lazysite {{lazysite_version}}. Authored from OPERATIONS-TEMPLATE; kept by the operator, not by the project."
brand: plain
standard-margins: true

# ---------------------------------------------------------------------------
# OPERATOR: fill in this block and nothing else. Every double-brace placeholder
# in this document - prose, tables, the title - is filled from here when the
# document is built. An unfilled placeholder stays literal and warns, so a
# half-completed declaration is visible rather than plausible.
#
#   md-to-pdf docs/compliance/OPERATIONS-TEMPLATE.md
#
# The same source can be rendered per deployment by passing a data YAML after
# the .md; the output filename follows the substituted title, so two instances
# do not overwrite each other.
# ---------------------------------------------------------------------------
vars:
  operator_legal_name:    "<registered company or individual name>"
  operator_contact:       "<email for security and regulatory contact>"
  service_name:           "<what you call this deployment>"
  lazysite_version:       "<e.g. 0.10.9>"
  update_channel:         "<edge | beta | stable>"
  environment_data_class: "<public | internal | personal-data | restricted>"

  security_triage_owner:  "<named individual - not a role>"
  security_triage_deputy: "<named individual>"
  release_manager:        "<named individual who gates deployment here>"

  reporting_authority:    "<coordinating CSIRT for your member state>"
  reporting_platform:     "<URL or channel>"
  reporting_access_verified: "<yes, on YYYY-MM-DD | NO - not yet verified>"

  declared_slo_pages:     "<e.g. 99.9% monthly, or 'project reference posture'>"
  declared_rto:           "<e.g. 4 hours>"
  declared_rpo_content:   "<e.g. 24 hours>"
  backup_schedule:        "<what runs, when, and where it writes>"

  declared_on:            "<YYYY-MM-DD>"
  signed_by:              "<name>"
  signed_role:            "<role>"
  signature_date:         "<YYYY-MM-DD>"
---

# Read this first

lazysite is software you deploy. **The project cannot make your deployment
compliant, and this file is the reason why.**

Under the Cyber Resilience Act and the eight-dimension framework the project
follows, a set of obligations attach to whoever *operates* a service rather
than to whoever *builds* the software. The project ships the mechanism -
backups and restore, `lazysite check`, the access log that measures
availability, the release channels, the audit trail. It cannot ship your
service register, your named security contact, or the fact that you rehearsed
your reporting path. Only you can record those, because only you know them.

::: widebox
**Your job with this file is to fill in the front matter, validate that what it
says is true of your deployment, and sign it.** Keep the filled-in copy
locally - it is your record, not the project's. Do not send it back to the
project; it may contain identifying and operational detail about your estate.
:::

If you are running lazysite for yourself with no external users and no
regulatory exposure, you may not need most of this. Read the "Does this apply
to me?" section, then keep the parts that do.

::: textbox
**You fill in one block.** Everything below reads back from the `vars:` map in
the front matter - including this document's own title. There is no second
place to edit and no value to keep in step by hand. Build it with
`md-to-pdf docs/compliance/OPERATIONS-TEMPLATE.md`; anything you have not
filled in stays visible as its own placeholder and warns during the build,
which is the behaviour you want from a document that gets signed.
:::

# Does this apply to me?

```datatable
columns: If your deployment... | Then
widths: X | X
bold: 1
tone: light
text: 2
---
serves only you, with no other users | Keep sections 1 and 5. The rest is optional.
serves an organisation internally | Keep sections 1-4. Reporting duties may still apply if the service handles personal data.
is offered to customers, or is placed on the EU market | All sections apply, and the reporting section has a date attached to it.
handles personal data | All sections apply, and your data-protection obligations sit alongside these rather than inside them.
```

# 1. Service identity and shape

This deployment is **{{service_name}}**, operated by **{{operator_legal_name}}**,
running lazysite **{{lazysite_version}}** on the **{{update_channel}}** channel,
with an environment data class of **{{environment_data_class}}**. Security and
regulatory contact: **{{operator_contact}}**.

The **update channel** is a compliance-relevant choice, not just a preference.
`stable` receives security fixes for the declared support period; `edge`
carries unreleased work and is not a channel to run a service on. If this
deployment is anything other than an experiment, it should be on `stable`.

The **environment data class** determines what else applies to you. Declare it
honestly - a staging environment holding a copy of production content is a
production data class.

# 2. Named people

Compliance obligations with clocks on them are met by people, not documents. A
role name is not sufficient: "the security team" cannot be telephoned at
22:00 on a Sunday.

Name individuals for:

security triage owner and deputy
: **{{security_triage_owner}}**, deputised by **{{security_triage_deputy}}** -
  who receives a vulnerability report and decides what it is. Two names,
  because one person is on holiday at some point.

release manager for this deployment
: **{{release_manager}}** - who decides that an upgrade happens here, and when.
  This is distinct from whoever cuts releases in the project.

Record how each is reachable out of hours. If you cannot fill this section
honestly, that is itself the finding - it means an obligation with a 24-hour
clock currently has nobody attached to it.

# 3. Reporting path - and the date on it

::: widebox
**CRA Article 14 reporting obligations are understood to apply from
11 September 2026.** If you place this service on the EU market, you have a
duty to report actively exploited vulnerabilities and severe incidents on a
24-hour / 72-hour / 14-day cascade. Confirm the date and whether it applies to
you with your own legal advice - the project cannot make that determination
for you.
:::

Before the clock is live, the path must be **exercised, not read about**:

- platform access verified for the named triage owner *and* the deputy.
  Authority: **{{reporting_authority}}**. Platform: **{{reporting_platform}}**.
  Access verified: **{{reporting_access_verified}}**;
- a test submission made where the platform supports one;
- the 24h/72h/14d cascade walked as a tabletop against a realistic scenario,
  including the clock-start judgement itself - awareness means a reasonable
  degree of certainty after an immediate initial assessment, and that call is
  rehearsable;
- the rehearsal recorded with date, participants and findings.

Repeat when the platform, the named people, or the obligation changes.

An untested reporting path fails at the moment the regulator's clock is already
running. This is the same argument as a restore rehearsal, with a shorter clock.

# 4. Service levels, backups and restore

For **{{service_name}}** the declared posture is: page-serve
**{{declared_slo_pages}}**, RTO **{{declared_rto}}**, RPO for content
**{{declared_rpo_content}}**, with backups **{{backup_schedule}}**.

The project publishes a reference posture in `docs/RELIABILITY.md`; you may
adopt it, tighten it, or loosen it, but the posture of record for your service
is the one declared here.

Whatever you declare must be backed by a **timed rehearsal**, not by the
existence of a backup command. Record each rehearsal with its date and its
measured recovery time in the maintenance schedule (see
`COMPLIANCE-MAINTENANCE-TEMPLATE.md`).

State your backup schedule: what runs, when, where it writes, and who would
notice if it stopped. The last of those is the one most often missing.

# 5. Monitoring

At minimum, know whether the service is up and whether it is serving errors.
The project ships the first-party access log, which measures availability
directly; `lazysite check` reports configuration and integrity problems
including whether the private content store is usable.

Record which monitors exist, what they watch, who receives an alert, and what
the response is. A monitor nobody receives is not a monitor.

# 6. Validation and signature

Do not sign this until you have **checked that each statement is true of the
running service** rather than true of the intention. Specifically:

- the named people know they are named;
- the reporting platform has actually been logged into;
- a restore has actually been performed, and timed;
- the alerts actually arrive somewhere a person reads.

declared on
: {{declared_on}}

signed
: **{{signed_by}}** - {{signed_role}} - {{signature_date}}

The signature is the point of the document. An unsigned operations declaration
records an aspiration; a signed one records that somebody checked.

# References

- `docs/compliance/COMPLIANCE-MAINTENANCE-TEMPLATE.md` - the recurring schedule
  that keeps this declaration true.
- `docs/compliance/OBLIGATIONS.md` - the project's dated obligations register,
  whose operate-side rows this declaration accounts for.
- `docs/RELIABILITY.md` - the reference SLO/RTO/RPO posture.
- `SECURITY.md` - the project's coordinated vulnerability disclosure contact.
