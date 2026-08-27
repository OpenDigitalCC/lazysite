---
title: "SM378: the safety snapshot refuses without saying why"
subtitle: "site_apply stopped with 'Refusing to apply: safety snapshot failed' - no path, no errno, no detail - while site_backup on the same host succeeded in both directions minutes later. The cause was not missing. It was discarded, at two levels, by three call sites."
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED 2026-08-18 on claude/sm378-snapshot-failure-says-why. action_backup_create now reports WHICH of three distinct conditions fired (tar exited N / wrote no archive / wrote an empty archive) and carries tar's own message as `detail`, scrubbed of filesystem paths. The three callers that discarded it - SitePackage apply, Backups restore, and the manager API - now pass the cause through. The REFUSAL ITSELF IS UNCHANGED and correct: an apply overwrites content, and the only thing worse than being unable to roll back is believing you can. This does not diagnose the field failure; it makes the next attempt diagnosable, which is what was actually missing."
---

# What was measured

A partner agent packaging one domain and applying it to another, both
registered on the same instance, was stopped by:

```json
{"ok":false,"error":"Refusing to apply: safety snapshot failed",
 "kind":"snapshot-failed"}
```

Ruled out before reporting: transient (three attempts), surface-specific
(MCP and the control API give the identical refusal), and caused by
`clean` (fails identically with and without it). The target was
untouched afterwards - the fail-safe worked.

::: widebox
**The contradiction beside it is what made this a defect rather than a
limit.** `site_backup` on that same host succeeded, within two minutes,
in both directions - including *after* the apply had already failed. So
the host can be snapshotted, and the apply path's snapshot of it cannot.
Nothing in the refusal could tell those two apart.
:::

# The cause was discarded, not absent

At two levels:

```datatable
columns: Layer | What it knew | What it returned
widths: 5.4cm | 5.0cm | X
bold: 1
tone: medium
---
`action_backup_create` | tar's exit status, tar's stderr, and which of three conditions fired | `Backup failed`
`apply` / `restore` / the API | the string above | `safety snapshot failed`
---
```

Three call sites made the second discard: `SitePackage::apply`,
`Backups::action_backup_restore`, and `lazysite-manager-api.pl`.

# The fix

`action_backup_create` distinguishes the three conditions, because they
are not the same fault:

- **tar exited N** - a tar problem
- **tar reported success but wrote no archive** - filesystem or permissions
- **tar wrote an empty archive** - tar believed it wrote and did not

and carries tar's own message as `detail`. The callers pass it through.

**Filesystem paths are never exposed**, and tar names them in almost
every message it emits, so the detail is scrubbed: paths under the
docroot or private store become `<site>/`, anything else absolute
becomes `<path>`. A remote caller learns about their site, not the host.

::: widebox
**This does not diagnose the field failure.** It makes the next attempt
diagnosable, which is what was missing. A refusal that will not say why
is its own defect, independent of whatever it was refusing about.
:::

# A near miss, recorded

The first draft reached for `sh -c` to redirect tar's stderr and used
`${@:3}` - a bashism that `dash`, Debian's `/bin/sh`, does not
understand. That would have broken **every backup on the platform this
ships to**, in the code whose entire job is to make things recoverable.
It is now list-form `system` with the redirect done in-process, so tar
is still exec'd directly with its arguments as a list.

# Verification

- A healthy snapshot is unchanged and still names the archive it wrote.
- A forced failure reports `tar exited 2` and carries tar's message.
- The real filesystem path does not appear in the detail; disabling the
  scrubber fails the test.
- Reverting to the bare `Backup failed` fails the test.
- No call site returns a bare refusal.

# Related

[[SM183]] (the artefact is the interface - a destructive operation
reversible on one surface and not another), [[SM313]] (`content_moved`,
the same lesson about a structural fact rather than a message).
