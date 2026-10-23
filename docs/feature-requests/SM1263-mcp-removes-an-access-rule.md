---
id: SM1263
title: "SM1263: MCP can remove an access rule"
subtitle: "An agent could set an access rule over MCP and never take one off: set_permissions with empty lists leaves an owner-only rule behind. remove_permissions is the twin of the control API's acl-remove and `lazysite acl remove`. The control API's acl-remove keeps its default, as SM306 ruled."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: "the release manager, ruling on SM1242's open question (2026-10-22); first reported by the xisl.com site agent (inbox 2026-10-20-set-permissions-says-a-draft-is-readable.md)"
area: mcp
status-note: "SHIPPED (0.16.1) on n725: MCP remove_permissions runs Files::action_acl_remove under manage_content, path-aware, audited as acl-remove; acl-remove is its declared twin; the control API's acl-remove keeps SM306's default, recorded in lints 52 and 265. t/unit/mcp/51."
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
- **The control API's acl-remove keeps its default, and the difference is recorded.**
  Pairing it with a tool that requires `path` brought it under lints 52 and 265. The
  dispatcher defaults `path` to `/` for every action, and `/` is the site-wide rule, so
  `acl-remove` with no path removes the rule on the whole site. SM306 kept that
  deliberately: un-protecting the root is what recovery looks like, and recovery must
  stay as easy as the mistake (t/integration/52, "recovery stays at least as easy as the
  mistake"). So the default stays, each lint records it with SM306's reason, and MCP
  requires the path, so an agent names what it removes.
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
- Lints 23, 52, 218 and 265 pass with the twin declared. t/integration/52 still holds
  SM306's recovery default.

# Not done

- **Whether the control API's acl-remove should need an explicit path.** A first cut of
  this change required it, and t/integration/52 refused it as SM306's ruling. The two
  arguments are: with no path, a script that drops its argument publishes a gated site;
  with a path required, an operator recovering a site types `path=/`. That is the release
  manager's choice to revisit, not this change's.
