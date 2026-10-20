---
id: SM1204
title: "SM1204: a newer OOM on the host does not fail the gate"
subtitle: "SM1202's test 78 failed whenever the host's odoo-oom held a model or profile the vendored snapshot lacks, so the 0.15.13 gate failed the morning OOM 0.37 was installed. Only an extra the suite actually uses fails now; the rest is reported."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: "the 0.15.13 release gate, 2026-10-20 (main 316d070ed), after OOM 0.37 was installed on the host at 09:32"
area: odoo
status-note: "SHIPPED (PENDING) on n693: t/unit/odoo/78 fails only for a host-only behaviour or profile that a test reaching OOM names; other extras are a TODO naming them. Sabotage: a test naming helpdesk.ticket fails it."
---

# What happened

The release gate for 0.15.13 (main 316d070ed, 2026-10-20) failed on one test:

> behaviours: nothing in the host's directory is missing from the snapshot, so it
> never answers ... The host's odoo-oom is newer than t/vendor/oom (behaviours:
> helpdesk.sla helpdesk.ticket helpdesk.ticket.category helpdesk.ticket.stage
> helpdesk.ticket.tag helpdesk.ticket.team)

and the same for the profile `helpdesk`. OOM 0.37 (libodoo-oom-perl, odoo-oom-packs,
odoo-oom-tools) had been installed on the host at 09:32, after the batch's
integration passed. The same tree passed integration on OOM 0.36.

[[SM1202]] wrote t/unit/odoo/78 to hold that the host's behaviours and profiles
never answer for the suite, because OOM always searches the deb's data directory
after the snapshot's own and offers no way to remove it. It held that by requiring
the host to hold nothing the snapshot lacks. That made the gate's result depend on
what is installed on the host, which [[SM1081]] rules out: every newer deb with a
new model failed the gate.

# What shipped

- Subtest 1 is unchanged: the snapshot's tree is searched first, so for every model
  and profile the snapshot has, the host's copy is never read.
- A model or profile that only the host holds can change a test's result only if a
  test asks OOM for it. The test now fails only when one is named by a file that
  reaches OOM: one that uses `OdooTest` or names an `Odoo::` module, or the Odoo
  test packs and fixtures. A word in a lint's list (t/lint/240) or a URL path
  (`/helpdesk` in processor test 75) reaches nothing and is not counted.
- Every extra is still reported, as a TODO naming them ("re-vendor when ruled").
  `tools/ext-compat.sh` remains the advisory tier for a newer OOM.

Evidence: with OOM 0.37 on the host the test passes, with TODO lines naming the six
helpdesk behaviours and the helpdesk profile. Sabotage: a scratch test that uses
`OdooTest` and names `helpdesk.ticket` makes subtest 2 fail, naming it.

# Not done

- The check is by name in the suite's files, not by what OOM resolved at run time.
  OOM does not say which root answered a lookup.
- Re-vendoring OOM 0.37 is a separate decision for the release manager.
