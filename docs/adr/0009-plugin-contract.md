# 0009 - Plugins declare what they own, and disabled means off

Date: 2026-08-19
Status: DRAFT - direction accepted; ratified when the data plugin ships as its
first conforming implementation
Tags: plugins, architecture, capabilities

## Context

Plugins live in the core checkout and their independence is partial in ways
that only show at the edges:

- **`enabled` is a label, not a state.** The `plugins:` list in lazysite.conf
  drives `_enabled` in the plugin listing - display and sort order - but
  `action_plugin_action` runs any registered plugin regardless, direct-CGI
  plugins (form-handler) are reachable with no plugin-level gate, and the MCP
  stats tool invokes its plugin unconditionally. An operator who disables a
  plugin has changed what the Plugin Manager page says, not what the site does.
- **What a plugin owns is discovered, not declared.** Its config keys, storage
  paths, endpoints, capabilities and dependencies are found by reading its
  code. Backup, site packages, the SBOM gate and the capability lints each
  learn about plugin-owned assets separately, which is how a plugin's data
  directory can be carried by one backup kind and silently dropped by another
  (found during the data-layer audit: SM410 finding B).
- The backlog's *plugin packaging / separation* entry states the goal:
  self-describing units, installable like a theme, with a documented interface.

The question was sequencing: retrofit the existing plugins to a designed
interface first, or build the next plugin to the target shape and extract the
interface from it.

## Decision

**Exemplar-first.** The contract is defined here in outline, the data plugin
(SM410) is built as its first conforming implementation, and existing plugins
are migrated afterwards, one per SM, post-stable. A contract extracted from one
real, demanding plugin beats one designed in the abstract and retrofitted seven
times: the data plugin exercises every clause below (own capability, endpoint,
storage, config, dependencies, migrations, backup participation), so any clause
that survives it is proven rather than speculative.

One clause is pulled forward independently of the data plugin, because it is a
fix rather than a feature: **making `enabled` real** (SM409).

## The contract, in outline

A plugin's `--describe` output grows a `owns` declaration:

    owns => {
        config_keys  => [qw(db_enabled db_source db_source_file ...)],
        storage      => ['lazysite/db/'],          # backup/package participation
        endpoints    => ['lazysite-data.pl'],       # direct-CGI surfaces
        capabilities => ['manage_data'],
        deps         => ['DBI', 'DBD::SQLite', 'YAML::PP'],  # sbom-deps keys
    }

and the platform consumes it instead of knowing:

- **Off means off.** Every dispatch path consults the enabled state: the
  Manager/Plugins.pm choke point refuses actions on a disabled plugin; a
  direct-CGI plugin refuses its own requests when disabled; MCP tools backed by
  a plugin refuse the same way. One rule, stated once: *a disabled plugin
  executes nothing and says so, with the house refusal shape.*
- **Backup and site packages read `storage`.** A plugin's data participates in
  content backups and site packages by declaration, not by whichever exclude
  list somebody remembered to edit.
- **The SBOM gate reads `deps`** and cross-checks sbom-deps.json, so a plugin
  adding a module cannot ship undeclared.
- **Capabilities registered by plugins** still walk the same nine parity points
  as core capabilities - the contract does not exempt a plugin from the lints,
  it makes the lints discover the plugin's entries.

What the contract does NOT attempt in this ADR: out-of-tree installation
(upload-like-a-theme). That is the backlog entry's end state; it needs the
signing/trust story a code-carrying artefact demands, and nothing about this
contract precludes it. Declare first, relocate later.

## Consequences

- The data plugin is built to this shape from its first commit (SM410).
- SM409 lands the enabled gate ahead of everything, because `db_enabled: yes`
  must mean something on day one - and because a "disabled" plugin that still
  executes is a standing defect today, independent of any new work.
- Existing plugins conform in a post-stable round, one per SM, mechanical.
- Until a plugin conforms, the platform's existing hardcoded knowledge of it
  stands - conformance removes entries from core lists rather than adding to
  them, which is the direction SM286 set for the front end.
