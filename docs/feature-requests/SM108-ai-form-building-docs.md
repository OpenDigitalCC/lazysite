---
title: "SM108 - AI form-building documentation"
subtitle: "Let an agent build and wire a form natively, not only by copying an existing one"
brand: plain
---

::: widebox
Agents successfully add a form by **copying the existing contact form**, but struggle
to build one **natively** - the `:::form` construct, its fields, and the two-step
"create the form, then bind it to a handler" flow are not discoverable enough from the
connector. They need a concise, authoritative form-building guide surfaced where the
agent looks.
:::

## Observed

An AI partner could replicate the contact page but not author a new form from scratch
- it did not know the `:::form` syntax, the field options, or that a form must be
**bound** to a delivery handler (`bind_form`) before it sends.

## What to add

- A **form-building section** the connector can read on demand: the `:::form` fence,
  supported field types (text/email/textarea/select/checkbox/honeypot), required vs
  optional, and the submit flow; then "bind it: call `list_form_handlers`, then
  `bind_form(form, handler)`" - a form only delivers once bound.
- Surface it from the tools the agent already uses:
  - `bind_form` / `list_form_handlers` descriptions point at the guide.
  - `whoami` / `get_permissions` mention "to add a form, see the form guide" when the
    account has `manage_forms`.
  - a `read_file` of a canonical `docs/forms.md` (or a dedicated `form_help` tool
    returning the syntax) so the agent can pull the spec without guessing.
- A minimal **worked example** (a 3-field enquiry form, fenced, then bound) - agents
  copy patterns well, so give them the canonical pattern to copy.

## Relationship

Extends [[SM087]] (connector editing ergonomics) and pairs with [[SM106]]
(`manage_forms` capability) and [[SM102]] (the agent can now report exactly this kind
of gap via feedback). The fix is mostly documentation + tool-description wiring, not
new mechanism.

## Status

Queued. Bounded: author the form guide, wire the form tools' descriptions + whoami to
point at it, and ship a canonical worked example.

## Status (reconciled)

**SHIPPED in v0.4.38.**
