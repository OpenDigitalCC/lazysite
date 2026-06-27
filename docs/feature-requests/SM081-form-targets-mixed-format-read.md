---
title: "SM081 - Form targets: mixed handler/type read drops the type targets"
subtitle: "action_form_targets_read skips the legacy block if any handler target exists"
brand: plain
---

::: widebox
`action_form_targets_read` (Manager::Plugins) parses `handler:` targets first,
then parses the legacy `type:` block **only `if (!@targets)`**. So a form config
that mixes both formats silently loses every `type:` target on read-back, even
though `action_form_targets_save` writes both. Found by the adversarial test
review of SM079a, 2026-06-24.
:::

## Status

**Fixed (2026-06-24).** `action_form_targets_read` now parses the YAML-ish list
in a single document-order pass, recognising either a `handler:` or a `type:`
entry at each list item (instead of skipping the legacy block whenever a handler
existed). A mixed-format config round-trips both targets in order;
`t/unit/lib/07-plugins-handlers.t` asserts the fixed behaviour plus the
all-handler and all-type round-trips.

## The bug

```perl
# Manager::Plugins::action_form_targets_read
while ( $text =~ /^\s*-\s+handler:\s*(\S+)/mg ) { push @targets, { handler => $1 } }
if ( !@targets ) {                     # <- skips legacy parse if ANY handler seen
    while ( $text =~ /^\s*-\s+type:\s*(\w+).../gms ) { ... push @targets, \%t }
}
```

A form with, say, an email `handler:` and a file-storage `type:` target reads
back as handler-only. `save` round-trips both formats; `read` does not.

## Fix

Parse both formats unconditionally and preserve document order (a single pass
that recognises either `- handler:` or `- type:` at each list entry), instead of
the two-pass `if (!@targets)` gate. Keep the existing save format. Add a
mixed-format round-trip assertion (replacing the current behaviour-pinning one).

## Impact

Low - most forms use one format. But a partner that wires both a stored copy and
an email handler (a plausible enquiry-form setup) would find the stored-copy
target vanish from the manager UI on reload, while still being honoured at
submit time (the dispatcher reads the conf directly). The mismatch is confusing.

## Status (reconciled)

**SHIPPED (2026-06-24, single-pass form-targets read; pinned by t/unit/lib/07-plugins-handlers.t).**
