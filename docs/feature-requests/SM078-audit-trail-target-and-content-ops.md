---
title: "SM078 - Audit trail: record the target of content / config / ACL operations"
subtitle: "The audit log captures the action name but not what it touched"
brand: plain
---

::: widebox
The manager audit trail records *that* a state-changing action happened - user,
action, IP, time, outcome - but not *what it touched*. A page create / update /
delete shows up only as a bare `save` / `delete` / `mkdir` with no path, so the
audit cannot answer "who changed this page, and when". The path already exists
in the application log (`log_event`), but the Audit page does not surface it.
:::

## Status

Queued - not yet specced. Observed 2026-06-24.

## The gap

`lazysite-manager-api.pl` audits every state-changing POST (`audit_log` at the
dispatch tail) as:

```
<ts> | <user> | <action> | <ip> | <ok|fail>
```

That is genuinely *all* it stores - there is no target column. So:

- Page **create / update / delete** (`save`, `delete`, `mkdir`) are recorded by
  action name only; you cannot tell which page was affected from the Audit page.
- The same is true for **config-set**, **acl-set / acl-remove**, **theme /
  layout** operations, and **cache invalidation** - the path/key is logged via
  `log_event` to `logs/` but never reaches the audit trail.

So the audit answers "did alice POST a save?" but not "what did alice change?",
which is the question an audit is for.

## Proposed change

- Extend `audit_log` to take an optional **target** (path / key / username) and
  add it as a column; update `action_audit` + the Audit page to show it.
- Populate the target at the call site for the content operations (`save`,
  `delete`, `mkdir`, `rename`), config (`config-set` key), ACLs (`acl-set` /
  `acl-remove` path), and theme/layout activate/install.
- Keep it single-line, pipe-delimited and sanitised (the existing format already
  strips `|` / newlines).
- Consider recording the **operation outcome detail** for deletes (e.g. file vs
  directory) so a destructive action is unambiguous in the trail.

## Considerations

- Backward compatibility: `action_audit` parses `split / \| /, $line, 5` - adding
  a column needs the reader to tolerate both old (5-field) and new (6-field)
  lines.
- Don't log secret *values* (only keys/paths) - the deny-set already keeps
  secret files out of content operations.
- This is the audit counterpart to the `log_event` application log; the two
  should agree on the target string.
