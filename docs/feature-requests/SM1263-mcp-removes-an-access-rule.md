---
id: SM1263
title: "SM1263: MCP can remove an access rule"
subtitle: "An agent could set an access rule over MCP and never take one off: set_permissions with empty lists leaves an owner-only rule behind. remove_permissions is the twin of the control API's acl-remove and `lazysite acl remove`. The control API's acl-remove now needs an explicit path, because its default was the site-wide rule."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: "the release manager, ruling on SM1242's open question (2026-10-22); first reported by the xisl.com site agent (inbox 2026-10-20-set-permissions-says-a-draft-is-readable.md)"
area: mcp
status-note: "SHIPPED (PENDING) on n725: MCP remove_permissions runs Files::action_acl_remove under manage_content, path-aware, audited as acl-remove; acl-remove is its declared twin; the control API's acl-remove requires path. t/unit/mcp/51, t/integration/71."
---

# What happened

An agent that set a rule over MCP could not remove it. `set_permissions` with empty lists
clears the lists, but the entry stays, owner and all. The control API has `acl-remove`
and the CLI has `lazysite acl remove`. MCP had no tool for it, and
`docs/architecture/access-control-model.md` told an agent to use the control API.

# What shipped

- **`remove_permissions { path }`** (lazysite-mcp.pl) runs
  `Lazysite::Manager::Files::action_acl_remove`, the function the control API and the
  CLI run. So it has the same behaviour throughout:
  - the same "Only the owner may remove permissions" refusal;
  - the same spellings of the site-wide rule (`/`), and the same refusal of a wildcard;
  - the same move of the content back into the document root;
  - the same `removed: 0` for a path with no rule.
- **The same capability.** It is `manage_content`, listed beside get_permissions and
  set_permissions in `Lazysite::Capabilities`, so describe_capabilities and the
  generated `docs/reference/capability-map.md` (regenerated with
  `tools/regen-generated.sh`) name it.
- **The same scope.** It is path-aware, so a confined caller can only remove a rule
  inside its scope.
- **The same audit action.** The MCP audit row's action is `acl-remove`, the control
  API's, with origin `mcp`. A refused attempt is a `fail` row.
- **Declared as the twin.** `acl-remove` in `Lazysite::ControlApi::Actions` names
  `mcp => 'remove_permissions'`, and lint 23's "no named twin" exemption is gone. Lint
  218 lists it beside set_permissions: an access rule moves a page between the trees,
  and no page text is written.
- **The control API's acl-remove needs an explicit path.** Pairing it with a tool that
  requires `path` brought it under lint 52 and lint 265, which found the hazard. The
  dispatcher defaults `path` to `/` for every action, and `/` is the site-wide rule.
  So `acl-remove` with the argument left out removed the rule gating a whole site and
  published it. A comment in Files.pm had called that default "harmless".
  - Its `path` is now `required => 1` in the registry, so the dispatcher refuses it:
    "path is required (... pass path=/ for the site-wide rule)".
  - The branch guards it as well, in acl-set's words (SM306).
- The connector tools page (`starter/docs/ai-connector-tools.md`) and the
  access-control model's surface table name the tool.

# Tests

- **t/unit/mcp/51** runs the real lazysite-mcp.pl:
  - the tool is listed for a manage_content caller and not for one without it;
  - a draft set by one account is refused to another with acl-remove's refusal, and
    removed by its owner (`removed: 1`, gone from the store, the page back in the
    document root);
  - a second removal answers `removed: 0`;
  - a caller without manage_content is refused;
  - the audit log has `acl-remove` rows for the path, from MCP, including the refused
    attempt.

  With lazysite-mcp.pl reverted, the tool's assertions fail.
- **t/integration/71**, new subtest: `acl-remove` with no path is refused, says to pass
  `path=/`, and leaves a site-wide rule in place. With the path spelled out, the rule is
  removed. With Actions.pm reverted, the branch guard still refuses, in its own words.
- Lints 23, 52, 218 and 265 pass with the twin declared.
