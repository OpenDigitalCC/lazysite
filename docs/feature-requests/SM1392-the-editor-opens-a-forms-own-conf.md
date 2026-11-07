---
id: SM1392
title: "SM1392: the manager's editor opens a form's own conf, and every door names manage_forms for it"
subtitle: "SM1371 opened lazysite/forms/<name>.conf to manage_forms over MCP, WebDAV and the control API, but the editor page marked every lazysite/ path read-only before asking the server. The editor now exempts a form's own conf, and MCP's read_file and write_file ask manage_forms for it, the path's own capability."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "the lazysite developer agent, from edge testing of 0.16.6 (brief n765)"
area: manager
status-note: "SHIPPED (PENDING) on n765: isFormConfPath in starter/manager/edit.md exempts a form's own conf from isReservedPath; lazysite-mcp.pl's tool gate asks manage_forms for read_file/write_file on that path. t/unit/manager/475. Docs: manager.md Files, ai-connector-tools.md."
---

# What happened

SM1371 (0.16.6) made a form's own configuration, `lazysite/forms/<name>.conf`,
`manage_forms`'s on every door: WebDAV (since 0.8.1), MCP's `read_file` and
`write_file`, and the control API's `read` and `save`
(`Manager::Files::_form_conf_refusal`, `Manager::Common::carveout_requirement`).
The manager's editor page never got that far. `starter/manager/edit.md`'s
client-side `isReservedPath` marked every `lazysite/` path "system file
(read-only)" and showed the control-area message, so the one door SM1371 named
for people - "the manager's file editor", in its UPGRADE note - did not open
for a manager holding the capability.

A second finding on the same path: an MCP caller holding neither
`manage_content` nor `manage_forms` was refused `read_file` on it with "needs
manage_content", a capability that never reaches the file. The tool gate asked
the tool's own capability first and the carve-out (which names `manage_forms`)
only after it.

# Change

## The editor exempts a form's own conf

`isFormConfPath` recognises `lazysite/forms/<name>.conf` by the shape the
server uses (`form_conf_name`: `[A-Za-z0-9_-]+`, never `smtp`, `handlers` or
`schedule`), and `isReservedPath` answers false for it before its `lazysite/`
rule. The page then asks the server's `read` as for any file; the server's
gate applies `manage_forms`, and a manager without it sees the server's
refusal, which names the capability, where it saw the control-area text. The
Files page's open-in-editor link is offered for a `.conf` as before
(`isEditable`, `TEXT_EXTENSIONS`), so the two pages agree.

## MCP asks the path's own capability

In `lazysite-mcp.pl`'s tool gate, `read_file` and `write_file` on a path
`form_conf_name` recognises ask `manage_forms` in place of `manage_content`, as
a `lazysite/layouts/` path asks `manage_themes or manage_layouts` in the same
block. A caller without it is told "needs manage_forms"; a caller holding
`manage_forms` alone reaches the file, as it has over WebDAV since 0.8.1 and as
the cookie `read`/`save` already allowed; a caller holding `manage_content`
alone is refused as before, now told the capability the path needs. The
carve-out pass and the write's rules (targets naming existing handlers only,
the form in reach, bindable handlers) run after the gate unchanged. Every other
path keeps the tool's capability: a page still needs `manage_content`, and
`smtp.conf` is refused as the tool's own capability, not as a form.

The control API's cookie `read` already named `manage_forms` for the path
(`carveout_refusal` and `_form_conf_refusal`); the token door has no `read`.
WebDAV already asked `manage_forms`. So every door names it now.

# Choices made

- The general gate is not weakened: the override is two tools on one path
  shape, the shape the server already admits to `manage_forms`. What it adds is
  the MCP reach of a `manage_forms`-only grant to a form's own conf, which
  WebDAV gave such a grant since 0.8.1; said in UPGRADE.md.
- The tool LISTING, ruling 152 (2026-11-07): widened, by the narrowest shape.
  The first commit left `_tool_callable` alone, so a `manage_forms`-only grant
  was admitted to `read_file`/`write_file` on the form conf and never offered
  them - SM210's shape. The release manager ruled that discovery matches
  enforcement, and that the rule must not list every path-aware tool for every
  path grant (the layouts override does that for a design grant, which is
  SM653's note). So each of the two tools DECLARES it: `cap_path => {
  manage_forms => 'form_conf' }`, a capability that admits the tool on one path
  shape, where the shape (`%CAP_PATH_SHAPE`) names its matcher
  (`form_conf_name`) and the words the listing uses for it. The gate in
  tools/call, `_tool_callable` and `_path_only_for` read that one declaration;
  `_path_only_for` now answers WHERE (theme and layout paths, a form's own
  configuration, or both), the listing's NOTE prints that answer, whoami's
  `tools_by_reach` gains `path_only_reach` per tool, each tool's description
  says what the `manage_forms` grant reaches, `manage_forms`'s `unlocks.mcp`
  names the two, and t/lint/90 reads `cap_path` as a gate. No other tool, and
  no other path shape, is offered to a path grant.
- `ai-connector-tools.md` said `nav.conf` and a form's conf are writable "with
  `manage_config`"; corrected to `manage_nav` and `manage_forms`, which is what
  the gates ask.

# Tests

t/unit/manager/475-the-editor-opens-a-forms-own-conf.t: the rule's source
(as t/unit/auth/16 reads the cookie split) and, under node, thirteen paths
through `isReservedPath`; the Files page's link for a `.conf`; over MCP a grant
holding neither is refused "needs manage_forms" and not `manage_content`, and a
page still "needs manage_content"; `manage_forms` alone reads and writes the
conf and nothing else; the cookie `read` without `manage_forms` names it and
with it opens the conf. With the change reverted the rule reserves the conf and
the MCP refusal names `manage_content`. t/unit/manager/461, 137, 176, 26,
t/unit/mcp/23 and t/lint/90, 92 pass unchanged.
