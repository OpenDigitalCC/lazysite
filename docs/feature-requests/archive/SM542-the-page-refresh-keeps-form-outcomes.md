---
title: "SM542: the page refresh keeps form outcomes"
subtitle: "A day first seen by the Stats page is finalised with empty form outcomes, and a later export never rewrites it."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): scan_first_party now calls _ingest_form_events before _persist_durable - the same fold _export_assemble makes - so both entry points write the same durable record and a closed day first reached by the Stats page refresh is finalised WITH its form outcomes; the byte-offset and final-marker contract is untouched. Proving test t/unit/plugins/30-the-page-refresh-keeps-form-outcomes.t reaches yesterday first through --scan and asserts the day file carries the stored and blocked outcomes, then runs --export and asserts it still does and the day is final. FOUND 2026-08-25 by the plugins structural review, PROVEN by probe tmp/plugins-probe-stats-scan-forms.pl; class: correctness; recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. --scan (scan_first_party, stats.pl 970-986) persists and finalises a closed day without calling _ingest_form_events, which only _export_assemble at 2852 calls, so a day first reached through the Stats page refresh is marked final with forms:{} and a later --export leaves it that way. The probe shows the day file forms={} after --scan, then form_delivery=[stored:1, blocked:{honeypot:1}] in the export while the day file still reads forms={} with final{2026-08-24}=1."
---

# The finding

`--scan` (`scan_first_party`, `plugins/stats.pl 970-986`) persists and
finalises a closed day without `_ingest_form_events`; only
`_export_assemble` (`plugins/stats.pl 2852`) calls it. A day first seen
by the Stats page is therefore marked `final` with `forms:{}` and a later
`--export` never rewrites it. The probe shows the day file `forms={}`
after `--scan`; after `--export` the export carries
`form_delivery=[stored:1, blocked:{honeypot:1}]` but the day file still
reads `forms={}` with `final{2026-08-24}=1`.

# Why it matters

Correctness: which durable record a day gets depends on which entry
point reached it first. The form outcomes for that day are lost from
the day file for good, because the `final` marker stops every later run
from revisiting it.

# The proving test

NEW `t/unit/plugins/30-the-page-refresh-keeps-form-outcomes.t` with
`is($day->{forms}{contact}{stored}, 1)`.

# Fix shape

Call `_ingest_form_events` from the `--scan` path before a day is
persisted and finalised, so both entry points write the same durable
record. The report treats this as a gap in what is written under the
incremental contract, and leaves the byte-offset and `final` marker
design alone.
