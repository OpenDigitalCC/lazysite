---
id: SM1090
title: "SM1090: a failed manager save is audited as a save"
subtitle: "A save that fails at the write leaves a row naming the save and the reason, not an edit that never happened."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: edge-testing agent, 2026-10-16
area: audit
status-note: "SHIPPED on n602: lazysite-manager-api.pl audit block; t/unit/manager/343."
---

# What happened

From the 0.15.5 edge test plan results, "Found outside the rows":

> Every cookie `save` answers 400 "Cannot write file: Permission denied (the
> file is not writable by the web-server user - run: lazysite check --fix)"
> ... The failures are not audited at all - only capability refusals are -
> and the last 200 audit entries (back to 2026-10-11) hold no successful save.

Driven here as a signed-in person against a folder the web-server user cannot
write, the failed save does reach the audit block (SM943 ruling 1 records an
error) - but the block renamed every save to `edit` or `create` from the
result's `created` flag, which only a successful save carries. The failed
row was therefore `edit`, whether the page was new or not, and a reader
looking for the `save` that failed, or for any `create`, found nothing. The
permissions fault itself is the host's (`lazysite check --fix`).

I could not reproduce a save that leaves no row at all; the row exists and
carries the reason, under the wrong action name.

# What shipped

The `edit`/`create` naming applies to a save that succeeded. A save that failed
keeps its own action, `save`, with `fail` and the write's reason as the detail
(`Cannot write file: Permission denied ...`), on the origin the request came
by. What a successful save records is unchanged.

t/unit/manager/343.
