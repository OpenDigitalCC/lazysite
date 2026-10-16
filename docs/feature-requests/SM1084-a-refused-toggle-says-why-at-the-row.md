---
id: SM1084
title: "SM1084: a refused extension toggle says why at the row"
subtitle: "The reason a toggle is refused appears under that extension, styled as an error, and not only in a muted line at the top of the page."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: release manager, 2026-10-16
area: manager
status-note: "SHIPPED on n598: starter/manager/plugins.md; t/unit/manager/341."
---

# What happened

The release manager enabled the Odoo extension on edge, where the OOM package
was not installed. The audit trail recorded the refusal and its reason:

    plugin-enable  odoo  fail  missing_deps: Odoo::Ops

In the release manager's words: "the toggle just springs back - it should
explain why it wont enable".

The server did explain. SM472's sentence comes back in `error`, naming the
missing module and the package that provides it. SM711 put the module names in
the audit row. The Extensions page wrote the sentence into its status line,
which sits at the top of the page above the list and uses the muted colour of
a progress line. An operator toggling a row further down saw only the switch
move back.

# What shipped

- A refused toggle puts the server's sentence under that extension's row, as
  a danger note with `role="alert"`.
- The status line carries the same sentence, styled `mg-status-error`.
- Toggling the row again clears the old note before the new request goes out.
- A toggle that cannot reach the server says so at the row as well.

t/unit/manager/341 drives the page's own functions in node.
