---
id: SM1325
title: "SM1325: a site can audit the AI reads of its content"
subtitle: "A successful read was kept off the audit trail by SM943's ruling. A site may now ask for the successful AI reads of its pages and files to be recorded there, with the account, the path and the time."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-04
raised-by: "the release manager, ruling 50 (Q5, T-17), on a protected agent-first intranet's gap G6"
area: security
status-note: "SHIPPED (PENDING) on n743: `audit_reads: on` in lazysite.conf; MCP read_file, read_page, view_version, preview_page and the control API's git-show for a token write one ok row each. t/unit/mcp/72."
---

# What was asked

Ruling 50 (2026-11-04): a read audit for each site, opt-in. When on, successful AI reads
(MCP and the control API) of pages and files are recorded in the existing audit with the
actor, the path and the time. Today only writes and failed reads are (SM943 ruling 1).
Off by default. Mind the volume.

# What shipped

The switch
: `audit_reads: on` in `lazysite/lazysite.conf` (also `true`, `yes`, `enabled`). Absence
  is off, and so is any other value - the other way round from `audit_trail`, which is on
  unless switched off, because this one records more about who read what.
  `Lazysite::Audit::audit_reads_state`, memoised on the conf's mtime and size as the trail's
  own switch is.

The reads
: named once, in `%Lazysite::Audit::CONTENT_READ`: the ones that hand back a page's or a
  file's content. MCP `read_file`, `read_page`, `view_version`, `preview_page`. The control
  API's `git-show`, for a token only: a token cannot call `read` or `preview` (cookie only),
  and `file-download` is audited always. A listing, a search or a status is not a read of
  content and is not recorded.

The row
: the trail's ordinary line: time, account, the tool or action, the path, the address,
  `ok`, the origin (`mcp` or `api`). `Lazysite::Audit::records_read` decides on both doors.

# Decisions taken (safest default, for confirmation)

- **Who switches it on**: whoever edits lazysite.conf - the operator, on the host. No
  manager, control-API or MCP surface sets it, and `config-set` refuses the key. If it should
  be switchable in the manager, the natural gate is the one the trail's own switch has:
  `manage_config` AND `audit_switch`.
- **AI reads only**: a signed-in person's reads on the manager are not recorded. WebDAV is
  not recorded either (the ruling names MCP and the control API).
- **Volume**: the rows go to `audit.log` and rotate with it under the shipped logrotate
  policy (weekly, eight kept). There is no separate cap. The manager's Audit page shows the
  newest 5,000 rows, so on a busy site the reads can push older changes off that page; the
  file keeps them.

# Tests

- **t/unit/mcp/72** (new), through the real MCP and control-API dispatchers. Off: none of
  the five reads writes a row. On: each writes one `ok` row with the time, the account, the
  path and the origin. On: `describe_capabilities`, `list_files` and a signed-in person's
  `git-show` write none. A value other than on is off.

Sabotaged one at a time, each fails the test: no MCP hook; no control-API hook; on by
default; any read recorded; a person's read recorded; any value read as on.
