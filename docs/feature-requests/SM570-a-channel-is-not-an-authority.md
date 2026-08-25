---
title: "SM570: a channel is not an authority - the ACL actions need manage_content"
subtitle: "acl-get, acl-set and acl-remove answered a token holding api, manage_themes and webdav. The gate was webdav OR manage_content, the registry agreed, and no lint compared either with what a channel capability means."
brand: plain
standard-margins: true
status: shipped
status-note: "FOUND BY THE SITE AGENT 2026-08-25 within ten minutes of the operator issuing a themes-only grant on edge (inbox filing): whoami showed api, manage_themes, webdav; acl-get returned real rules for paths the account owned; acl-set/acl-remove completed a full cycle against a nonexistent path; every other gated action in a 22-action sweep refused correctly, DAV refused content writes, MCP was closed. ROOT CAUSE: %need gated all three as `webdav || manage_content` - SM074's era, when a WebDAV publishing partner managed the rules on its own files - and ControlApi::Actions declared the same pair, so the registry-agreement view was clean. But `webdav` is a CHANNEL enablement (which door a grant may use), never an authority: a webdav-only grant cannot PUT content over DAV, yet it could read, set and remove the rules that govern content. Ownership checks inside the actions held (SM464 read split, owner-only writes), so the exposure on edge was bounded to rules the account owned and to paths that had no rule yet. SHIPPED 0.10.32 (the beta build, before publish): the three gate on manage_content alone in %need and the registry; t/lint/86 forbids any channel capability (webdav, api, mcp, ui) in a token gate, requires every gated action in the registry, and requires the two to agree; t/unit/manager/10 pins the refusal for a manage_themes+webdav token and the success once manage_content is granted. SEVERITY, AT ITS PROVEN LEVEL (two-principal evidence): PROVED - any principal could CLAIM a rule-less path: acl-set on it made the caller the owner and could restrict its readers, a real escalation and a denial-of-access vector against public content. DISPROVED (2026-08-25, second principal issued by the operator) - a non-owner could not acl-get, acl-set or acl-remove an EXISTING rule ('Not the owner of this file' / 'Only the owner may change permissions' / 'Only the owner may remove permissions') and the gated content stayed 403 throughout; t/unit/manager/18 F1 pins the same. So a webdav token could neither un-gate protected content nor rewrite another owner's rule. The fix was still right: a channel flag standing in for a permission is wrong regardless of the per-file layer, and defence in depth (the ownership layer) is what bounded it. REACHABLE SET: every grant holding webdav AND api - most publishing partners - since SM074, not themes grants specifically; whether that is a disclosure question for client sites is the operator's call. THE FLOOR ROW IS THE DEFINITIVE STATEMENT (agent, 2026-08-25, on 0.10.31): an account holding NO capabilities at all - only the api/mcp/webdav channels - had six callable actions, three of them acl-get/acl-set/acl-remove; every other one of 135 actions refused. Any token holder, whatever their group. THE METHOD FINDING outranks the bug: every field pass since 0.10.28 was made holding manage_content, so a gate satisfiable by a weaker grant was invisible by construction - a weaker credential makes the question askable. The agent's sweep is to be repeated per grant shape (manage_content-only, manage_layouts-only) when the operator issues them."
---

# The escalation

A themes-only grant carries `webdav` so it can upload theme files. The
ACL actions accepted `webdav` as sufficient. So a partner that cannot
write a single content page could read the rules on paths it owned and
claim any path that had no rule yet.

# What two principals proved

- **Proved.** Any principal could claim a rule-less path: `acl-set` on
  it made the caller the owner and could restrict its readers - a real
  escalation, and a denial-of-access vector against public content.
- **Disproved** (2026-08-25, a second principal issued by the
  operator). A non-owner could not `acl-get`, `acl-set` or `acl-remove`
  an existing rule - "Not the owner of this file", "Only the owner may
  change permissions", "Only the owner may remove permissions" - and
  the gated content stayed 403 throughout. Protected content could not
  be un-gated and another owner's rule could not be rewritten.

The fix was still right. A channel flag standing in for a permission is
wrong whatever the per-file layer does; defence in depth is what bounded
the exposure, and the gate now says what the ownership layer enforced.

# The rule, now structural

A channel capability says which door a grant may use; it never says what
the grant may do through it. `t/lint/86` forbids `webdav`, `api`, `mcp`
and `ui` from every token gate, and keeps the gate and the registry in
agreement so `describe-capabilities` tells the truth the dispatcher
enforces.

# What it changes for WebDAV partners

SM074 let a WebDAV publishing partner manage the rules on its own files
with `webdav` alone. Such a partner already needs `manage_content` to
write content at all, so the practical change is nil for a real
publishing grant - and decisive for a grant that only ever meant themes.
