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
status-note: "SHIPPED (PENDING) on n743: `audit_reads: on` in lazysite.conf, switched on the Config page by manage_config AND audit_switch (ruling 96), written to logs/audit-reads.log and shown under the Audit page's AI reads view (ruling 97); MCP read_file, read_page, view_version, preview_page and the control API's git-show for a token write one ok row each. t/unit/mcp/72."
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

Who switches it (ruling 96)
: the Config page (Record AI reads, in Audit) and `config-set` (`audit_reads`: `on`, `off`
  or empty), for an account or a token holding `manage_config` AND `audit_switch` - the
  gate of the trail's own switch (`audit-trail-set`). `manage_config` alone is refused,
  naming the permission it lacks, and nothing is written. The switch is a change, so it
  is on the change trail. The operator can still set it in the file.

The reads
: named once, in `%Lazysite::Audit::CONTENT_READ`: the ones that hand back a page's or a
  file's content. MCP `read_file`, `read_page`, `view_version`, `preview_page`. The control
  API's `git-show`, for a token only: a token cannot call `read` or `preview` (cookie only),
  and `file-download` is audited always. A listing, a search or a status is not a read of
  content and is not recorded.

The row (ruling 97)
: the trail's ordinary line - time, account, the tool or action, the path, the address,
  `ok`, the origin (`mcp` or `api`) - written by `Lazysite::Audit::audit_read_log` to a file
  of its own, `logs/audit-reads.log`. The shipped logrotate stanza covers `logs/*.log`, so
  it rotates as `audit.log` does; it is forwarded to syslog as the trail is
  (`forward_audit`); `audit_trail: off` stops it too. `records_read` decides on both doors.

The Audit page
: Show: Changes / AI reads. `audit` takes `view=reads` (declared), which reads the reads
  file with its own cache and its own 5,000-row window, so reads never push a change off
  the change view. The answer names its `view`.
  Its trail-health state is the reads file's own (appendable, unwritable, unreadable, and
  `reads-off` when the read audit is not on), and the installer and `lazysite check` keep
  the file group-writable, from the permission model beside `audit.log`.

# Decisions

- **Who switches it on**: ruling 96, above.
- **AI reads only**: a signed-in person's reads on the manager are not recorded. WebDAV is
  not recorded either (the ruling names MCP and the control API).
- **Volume**: ruling 97, above - a file of its own, rotated as the trail is (weekly, eight
  kept, where the stanza is installed).

# Tests

- **t/unit/mcp/72** (new), through the real MCP and control-API dispatchers. Off: none of
  the five reads writes a row. On: each writes one `ok` row with the time, the account, the
  path and the origin. On: `describe_capabilities`, `list_files` and a signed-in person's
  `git-show` write none. A value other than on is off. None of the reads is on the change
  trail. `config-set audit_reads` is refused to `manage_config` alone (nothing written) and
  done for `manage_config` with `audit_switch`; a bad value is refused. `audit&view=reads`
  lists the read; the change view does not, and lists the switch.

Sabotaged one at a time, each fails the test: no MCP hook; no control-API hook; on by
default; any read recorded; a person's read recorded; any value read as on; reads written
to the change trail; the config gate without `audit_switch`; the reads view reading the
change file.
