---
id: SM1119
title: "SM1119: a required argument agrees across the two surfaces"
subtitle: "An argument one surface requires is required on the other, or the difference is recorded with its reason."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: release manager, 2026-10-17 (task #231, from SM306)
area: control API
status-note: "SHIPPED on n622: Lazysite::ControlApi::Actions `required` declarations; t/lint/265, t/unit/manager/206."
---

# What happened

From SM306, as filed for task #231:

> MCP set_permissions declares required=>['path']; the control API invented a
> dangerous default for the same argument, and both looked correct to every
> check. SM239 pins that the two surfaces expose the same ACTIONS and
> t/lint/23 records deliberate one-sided ones, but nothing compares what they
> REQUIRE. For each paired action, an argument required on one surface should
> be required on the other or the difference recorded with a reason.

t/lint/52 (SM326) closed the one hazard SM306 hit, the dispatcher's `path`
default. Every other argument was still unchecked. Comparing every paired
action's `required` list with its MCP tool's found forty argument differences across some thirty-five actions.

# What shipped

t/lint/265 compares, for every action that names an MCP `twin`, the arguments
the action marks `required => 1` with the tool's `required` list. A
difference passes only if it is in the lint's `%DIFFERENCE` table with a reason
taken from the code, or is the same argument spelled two ways (`%SPELLED`:
git `sha` / MCP `version`, theme `path` / MCP `theme`).

The control API side was the one that was wrong, in every case where the
handler already refused the absent value or acted on it. Marked `required => 1`
(the dispatcher now answers the absence by name, before the handler):

- data tables and rows: `table` on data-table, data-table-source, data-rows,
  data-migrate, data-migrate-plan, data-rebuild, data-table-save,
  data-table-drop, data-row-save, data-row-delete; `descriptor` on
  data-table-save; `row` on data-row-save; `key` on data-row-delete; `file`
  on the three data-safety-export actions.
- `host` on domain-preview and site-backup-create; `host` and `key` on
  domain-set; `id` on connector-call; `form` and `confirm` on form-delete;
  `path` on git-history, git-restore, git-show and theme-delete; `sha` on
  git-show and git-restore.
- nav-save `items`: the handler read `$req->{items} // []`, so a request with
  no `items` saved an EMPTY navigation and wiped the menu, the SM306 shape.
  `items` is required now; an explicit `"items": []` still clears it.

Hoisting the refusal wrote no audit row, where the handler's own refusal had
written one (t/unit/manager/206, git-show), so the dispatcher's missing-parameter
refusal is audited now, as a refusal is everywhere else (SM943 ruling 1).

Recorded in `%DIFFERENCE`: acl-get `path` (absent reads the root
rule, SM310), acl-set `path` (`paths` list, SM1052), brief-delete `path`
(typed reference, SM696), layout-delete `layout` (`path` still works, SM911),
form-submissions `form` (`file`, SM862), form-uploads-save `uploads` (absent
means off, SM905); and layout-install `layout` and site-backup-apply `name`,
whose handlers read the raw body, which the extractor behind t/lint/58 cannot
see, so they declare no parameters and refuse the absent value themselves.

t/lint/265; t/unit/manager/206 now sends an invalid `sha` to reach the handler refusal it means to test.
