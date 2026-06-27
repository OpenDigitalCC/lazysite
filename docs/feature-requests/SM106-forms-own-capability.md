---
title: "SM106 - forms as its own capability"
subtitle: "Grant form management with content (default) or separately"
brand: plain
---

::: widebox
Managing forms - binding a form to a handler/transport (`bind_form`), editing
`handlers.conf` - is currently gated by **`manage_content`**. Like navigation
([[SM105]]), forms are arguably their own concern: a site may want someone who owns
the contact/enquiry forms and their delivery without write access to page content, or
the reverse. Give forms their own capability, defaulting to inherit from content so
nothing breaks.
:::

## Current behaviour

- **Connector / partner**: `bind_form` / `list_form_handlers` are gated by
  `manage_content` (lazysite-mcp.pl).
- **Operator (manager UI)**: bypasses the capability gate.

## Proposal

- Introduce **`manage_forms`** as a distinct capability.
- **Effective forms permission = `manage_forms` if set, else `manage_content`**
  (inherit), so every account that manages content today keeps managing forms with no
  migration.
- Surface it as a toggle in the Users-page "Publishing access" group, grantable with
  content (default) or independently.
- Apply on both surfaces: the form tools' `cap` in the MCP, and the partner gate for
  `forms/` + `handlers.conf` writes.

## Why

Forms carry delivery configuration (where submissions go - email, webhook). Separating
the capability lets an operator delegate "owns the forms and where they deliver"
without granting full content write, and vice versa.

## Relationship

Same pattern as [[SM105]] (nav as its own capability); both are the granular-capability
direction and both compose with [[SM095]] (group-based capabilities). Worth doing
together: one "inherit from manage_content unless explicitly set" mechanism serves
`manage_nav`, `manage_forms`, and any future split-out.

## Status

**SHIPPED in v0.4.26.** (see CHANGELOG)


Queued. Bounded: a new capability key with content-inheriting default, `cap` changes
on the form tools, the partner gate for `forms/`/`handlers.conf`, and a toggle in
`users.md`.
