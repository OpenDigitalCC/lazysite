---
title: "SM153 - Manager UI test guide (chunked, compile-merged)"
subtitle: "A menu-complete test/walkthrough document for human review, agent onboarding, and tutorial authoring"
brand: plain
status: shipped
status-note: "SHIPPED on main (unreleased). docs/manager-ui-guide/, ten numerically-prefixed chunks merged by the pandoc pipeline (md-to-pdf --order-alpha), which was chosen over dogfooding ::: include because these are DOCS rather than site content and the house style already builds docs this way. Every entry uses the filing's fixed template - Where / Do / Expect / Negative - and the Negative row is the one that earns the format: it is where an unenforced capability hides and the part a hurried author leaves out. THE COVERAGE RULE IS ENFORCED, not promised: t/lint/32-manager-guide-covers-the-nav.t parses the nav out of starter/lazysite/manager/layout.tt and fails in BOTH directions - a new menu item with no entry, and a chunk that drops a template field. Confirmed failing on both drifts before being committed. The filing said a lint 'can later' do this; later is how a walkthrough document rots, and a guide whose value is completeness misleads a reviewer with one missing entry in a way they cannot detect. An item that should not have a walkthrough is declared 'Intentionally omitted:' with a reason and counts as covered - used once already, for the retired group dav_scope on the Groups chunk. Chunks: how-to-use, Files, Navigation, Appearance, Plugin Manager + Config, Users, Groups, Sessions and keys, Site settings, Domains, Cache/Backups/Audit/Stats, and Agents and connectors (MCP, control API, WebDAV, scope confinement on every channel, agent-facing docs). docs/MANUAL-CHECKS.md now states the split: that document is what the suite structurally cannot reach and why; this guide is menu-complete coverage for reviewing the product rather than a change. ORIGINAL: requested 2026-07-15; targeted for a later round after the domains work"
---

# SM153 - Manager UI test guide

A single, menu-complete document that lists **every** manager-UI menu item and
action, and for each one gives a human tester: how to exercise it, and what to
expect. Authored in **per-section chunks** for maintainability and **merged into
one document at compile time**.

## Why

- **Human review.** A durable walkthrough so a person can review the whole
  manager UI surface end to end, not just the paths that happen to have a test.
- **Agent onboarding.** Includes the "connect a different agent" flows (MCP
  connector, control-API token/bearer, WebDAV partner) so the review covers the
  agent surfaces as well as the browser UI.
- **Tutorial checklist.** The same longlist is the canonical checklist for
  writing user tutorials across every function - if it is in the guide, a
  tutorial is owed for it.

## Shape

- **One chunk per manager section**, e.g. `Files`, `Users & groups`, `Themes`,
  `Layouts`, `Navigation`, `Forms & handlers`, `Site settings`, `Domains`
  (SM151), `Backups`, `Content history`, `Audit`, `Sessions`, `Keys`, `Plugins`,
  `Analytics`, plus an `Agents & connectors` chunk (MCP / API token / WebDAV).
- **Per item**, a fixed template: *Where* (menu path) - *Do* (the action) -
  *Expect* (the observable result, including the audit-trail entry and any
  capability gate) - *Negative* (what a user lacking the capability should see).
- **Merged at compile time.** Two candidate mechanisms, decide during design:
  1. Dogfood lazysite's own `::: include` - each chunk is a page, a parent page
     includes them in order (also proves the include feature on real content).
  2. The pandoc pipeline's multi-input merge (`md-to-pdf` with ordered inputs)
     for a branded PDF deliverable.
  Chunks live under a stable directory (e.g. `docs/manager-ui-guide/NN-<section>.md`)
  with a numeric prefix so ordering is explicit.

## Coverage rule

The guide is **menu-complete**: every item that appears in the manager
navigation (and every connector/agent entry point) has an entry, or an explicit
"intentionally omitted" note. A lint check can later diff the guide's item list
against the rendered manager nav so a new menu item can't ship without a guide
entry (mirrors the `check-no-cdn` / SBOM-gate discipline).

## Relationship to existing work

- Complements the automated suite (`t/`): the suite proves behaviour; this guide
  drives **human** review and tutorial authoring, and covers presentation/UX the
  suite doesn't assert.
- The `Domains` chunk depends on the SM151 multi-domain admin surface (the .17
  domain discussion) - the guide entry and the feature land together.
- The `Agents & connectors` chunk reuses SM124 (connector onboarding) and SM126
  (agent capability discovery) content.
