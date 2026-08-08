---
title: "SM239 - MCP and control-API surface parity, enforced"
subtitle: "The two remote channels have drifted apart one action at a time, with nothing recording whether a gap is deliberate. Audit them, declare the intended relationship, and pin it with a drift guard."
brand: plain
status: candidate
status-note: "Raised by the operator 2026-08-07 after SM238 found the domain tools present on the control API and wholly absent from MCP. The point is not a one-off backfill: without a guard the surfaces drift again on the next feature. This codebase already has the right pattern for that (t/lint/17,18,19 and the guarantee registries) and this should use it."
---

# SM239 - MCP and control-API surface parity

## Why

SM238 found that `domain-set`, `domains-list`, `domain-preview` and their
siblings exist on the control API and have no MCP equivalent, under the same
`manage_domains` capability. That gap was not a decision anyone made. It is what
happens when two surfaces are extended one feature at a time and nothing checks
them against each other.

The consequences are not symmetrical with the omission. An agent on the MCP
channel could not do the scoped thing it was asked to do, and the only tool it
had was broader than the request. A capability the operator granted did not
deliver what the capability map said it unlocks.

Backfilling the domain tools fixes that instance. It does nothing about the next
one, and there will be a next one: every future feature is authored on whichever
channel its author was working on.

## What the relationship actually is

"Equal" needs stating precisely, because full one-to-one parity is the wrong
target and asserting it would produce a test nobody can keep green.

Some divergence is correct and permanent:

- **UI-only capabilities.** `manage_users`, `notifications`, `create_sub_users`
  and `delegate_sub_user_creation` unlock manager pages. They have no remote
  surface on either channel and should not acquire one.
- **WebDAV path shapes.** `manage_content` and `manage_themes` unlock path
  prefixes over WebDAV, which is a different kind of thing from an action and
  does not map to a tool.
- **Channel-shaped operations.** Streaming a backup download suits an HTTP action
  in a way it does not suit a tool call.

Everything else should be reachable from both remote channels. The working rule:

> If a capability unlocks an action on one remote channel, it should unlock an
> equivalent action on the other, unless a recorded reason says why not.

The load-bearing words are **recorded reason**. Today a gap and a decision are
indistinguishable.

## What to do

### 1. Audit

Build the full correspondence between control-API actions and MCP tools, grouped
by capability, and mark each row: paired, API-only, or MCP-only. The capability
map's `unlocks` block already holds both lists per capability, so most of this is
derivable rather than hand-collected - and where `unlocks` is wrong, that is
itself a finding.

Expect the audit to surface more than the domain tools. `manage_config`
(`config-read`, `config-set`, `git-init`), `audit`, and the alias and history
actions are all worth checking.

### 2. Decide each gap, once

For every unpaired action: build the twin, or record why it will never exist.
Both outcomes are acceptable; leaving it unexamined is not.

The gaps SM238 already identified are in scope for that request and should not be
done twice here.

### 3. Pin it with a drift guard

This is the part that matters, and this codebase already knows how to do it.
`t/lint/17-dav-shared-parity.t`, `18-config-key-parity.t` and
`19-capability-grid-parity.t` all mechanically pin one surface against another,
and the audit and git guarantee registries require every new action to be
*classified* rather than merely present.

A new lint test should walk the control-API action table and the MCP `%TOOLS`
map, pair them, and fail on any unpaired entry that is not in a declared
exemption list carrying a reason. The exemption list is the deliverable as much
as the test: it turns "these differ" into "these differ, and here is why".

The failure message should name the action and say what the author must do -
build the twin or add an exemption - because the test will be met most often by
someone who has just added a feature and does not know this rule exists.

### 4. Say it in the capability map

Once the surfaces are declared, `describe_capabilities` should be honest about
per-channel availability, so an agent can tell "not on this channel" from "not
granted" from "does not exist". SM226 established the vocabulary for exactly this
distinction and this is the third case it should cover.

## Verification

- Every capability's `unlocks` block matches the live action and tool maps in
  both directions.
- An action added to one channel without a twin or an exemption fails the lint
  suite, with a message naming the remedy.
- The exemption list carries a reason per entry, and the UI-only capabilities
  are exempt by category rather than one at a time.
- No capability changes what it permits.

## Not in scope

- Building the domain tools. That is SM238.
- Parity with WebDAV. It is a filesystem protocol, not an action surface, and
  `t/lint/17` already guards what it shares.
- Making the two channels identical in shape. A tool has typed parameters and a
  description; an API action has a query string. Parity is about what is
  reachable, not how it is spelled.

## Audit done, guard enforced (2026-08-08)

Built as `t/lint/23-mcp-api-action-parity.t`, 247 assertions. A first cut in
0.10.2 compared capability-level SHAPE only and said in its own header that it
would not have caught SM238; this replaces it.

### The map was incomplete, which is the finding under the finding

Building the pairing surfaced that **thirteen real control-API actions appeared
in no `unlocks` list at all**: `artifact-manifest`, `artifact-validate`,
`artifact-backups-delete`, `bad-url-blocks`, `bad-url-unblock`, `lang-status`,
`preview-grant`, `site-backup-delete`, `site-backup-inspect`,
`site-export-primary`, and the three ACL actions.

So `describe_capabilities` was under-reporting what every capability gives, and
the first cut - which read `unlocks` - was measuring an incomplete map. All
thirteen are now placed, and the guard checks completeness FIRST, because a
parity check reading a partial map measures nothing.

The ACL trio turned out to be a different case worth recording: `acl-get` /
`acl-set` / `acl-remove` are gated by the **webdav CHANNEL** capability rather
than an action capability, so they have no action-capability home by design. The
channel's own description now names them.

### What the pairing found

**21 paired**, via a name map - the twins are spelled differently on the two
channels (`form-submissions` / `read_form_submissions`), which is exactly why a
naive comparison could not work.

**Content file operations pair with WebDAV, not with a control-API action.** The
API channel does file work over `/dav`, so `write_file`, `move_file`,
`get_permissions` and a dozen others have no control-API twin and should not.
Listing them as one-sided would have produced a dozen false positives and taught
readers to ignore the list.

**24 API-only and 13 MCP-only**, each now carrying a reason. Seven are
deliberate: the domain verbs held by SM238, the byte-streaming backup actions
that belong on WebDAV, `preview-grant` minting a browser cookie, and
`upload_file` being MCP-only for the mirror-image reason. The rest read
**undecided** - the honest answer, and the point of recording it, because a gap
nobody has looked at should read differently from a gap someone chose.

The largest undecided cluster is `manage_config`: `config-read`, `config-set` and
`git-init` have no MCP twin at all. Then `audit`, which means an agent cannot read
the audit trail over MCP.

### What the guard catches

- An action or tool added to one channel with no twin and no recorded reason.
- An action callable but absent from `unlocks` - the class that hid thirteen.
- A stale reason: one recorded for something since paired or removed, which reads
  as a live decision and is worse than no entry.

It would have caught SM238.

### Still open

The `undecided` entries are decisions, not defects - each is a small question
about whether a given operation belongs on the connector. They can be worked
through in any order now that they are visible and cannot silently grow.
