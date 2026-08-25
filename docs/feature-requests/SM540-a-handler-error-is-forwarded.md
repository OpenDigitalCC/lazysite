---
title: "SM540: a handler error is forwarded"
subtitle: "Plugin diagnostics stay on STDERR, so with forward_diagnostics on a submission failure never reaches syslog."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): each of the four plugin log_event copies hands the line it printed to a best-effort _forward_diag that locates the module tree at runtime and eval-requires Lazysite::Util (no `use lib`; a missing lib costs a syslog copy, never a submission) and calls forward_line at the mapped priority, so the one forwarding implementation stays in Util; audit.pl exports its --docroot as DOCUMENT_ROOT so the conf peek finds lazysite.conf. Proving test t/unit/forms/12-a-handler-error-is-forwarded.t drives form-handler, form-smtp --pipe and audit --scan through the LAZYSITE_SYSLOG_DUMP seam and asserts the err / info lines land, that nothing lands with forwarding off, and pins payment-demo at source. FOUND 2026-08-25 by the plugins structural review, PROVEN by probe tmp/plugins-probe-forms-forwarding.sh; class: operability; recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. form-handler, form-smtp, audit and payment-demo each carry a private ~40-line log_event that predates forward_line in Lazysite::Util, so with forward_diagnostics: true an ERROR from a submission is written to STDERR only while the same call through Lazysite::Util lands in the dump. FEATURES.md 579-583 and CHANGELOG 5939 promise application diagnostics without excluding plugins. The processor's own module-free copy is ADR 0001 and a separate decision."
---

# The finding

Plugin diagnostics never reach syslog. The four private `log_event`
copies (`plugins/form-handler.pl 1134-1173`, `plugins/form-smtp.pl
368-407`, `plugins/audit.pl 497-536`, `plugins/payment-demo.pl 197-236`)
predate `forward_line` in `Lazysite::Util` (Util.pm 52-105), so with
`forward_diagnostics: true` an ERROR from a submission is written to
STDERR only. The probe shows the dump `(empty - nothing forwarded)`
after the handler and `err [...] [lazysite] [form] processing failed`
after the same call through `Lazysite::Util`. The docs (FEATURES.md
579-583, CHANGELOG 5939) promise application diagnostics without
excluding plugins.

# Why it matters

Operability: the operator who turned forwarding on to watch their forms
sees nothing when a submission fails. The promise in the docs and the
behaviour of the plugins disagree, and the gap is invisible until it
matters.

# The proving test

NEW `t/unit/forms/12-a-handler-error-is-forwarded.t` with
`like(slurp($dump), qr/^err .*processing failed/m)`;
`unit/lib/17-log-forwarding` 'ERROR forwards at err priority' is the
model.

# Fix shape

Bring `forward_line` (and the undef guards) into the four plugin copies,
or let the plugins reach `Lazysite::Util::log_event`. The report notes
that the tidy row PL-20 depends on this choice, and that the processor's
own module-free copy (ADR 0001) is a separate decision.
