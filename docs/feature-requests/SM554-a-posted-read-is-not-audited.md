---
title: "SM554: a posted read is not audited"
subtitle: "POST action=notices and POST action=layouts-manifest each write an ok audit row, so two reads appear in the audit trail as though they changed something."
brand: plain
standard-margins: true
status: candidate
status-note: "FOUND 2026-08-25 by the manager-api structural review, PROVEN by probe tmp/mapi-probe-audit-target.t; class: operability; recommended timing: later. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. The audit skip list (%skip, lazysite-manager-api.pl 1745) omits notices and layouts-manifest; the probe shows POST action=notices and POST action=layouts-manifest each write an ok audit row with target /. They are the only live members of KNOWN minus MUTATING minus %skip - the others stream and exit before the audit block, and users has its own block. Fix from the report: add both to %skip."
---

# The finding

The audit skip list `%skip` (`lazysite-manager-api.pl 1745`) omits
`notices` and `layouts-manifest`. The probe shows `POST action=notices`
and `POST action=layouts-manifest` each write an `ok` audit row with
target `/`.

The report's set diff (`tmp/mapi-sets.out`) puts them as the only live
members of KNOWN minus MUTATING minus `%skip`: the other members
(`backup-download`, `data-export`, `file-download`, `file-zip-download`,
`site-backup-download`) stream and exit before the audit block, and
`users` is handled by its own block.

# Why it matters

Operability: the audit trail is read as a record of changes. Two
read-only actions writing rows on every POST add noise that an operator
has to learn to discount.

# The proving test

NEW t/unit/manager/98-a-posted-read-is-not-audited.t (assertion: no
`| notices |` line after a POST).

# Fix shape

Add `notices` and `layouts-manifest` to `%skip`.
