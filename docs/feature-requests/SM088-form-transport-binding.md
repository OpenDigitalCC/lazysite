---
title: "SM088 - Binding a form to a transport via the connector"
subtitle: "Let the AI wire a new form to delivery without touching credentials"
brand: plain
---

::: widebox
A `:::form` block renders and posts to `form-handler.pl`, but it only *delivers*
if a matching `lazysite/forms/<name>.conf` handler exists. That config is
deliberately deny-listed (blocked-config) from the connector because it carries
delivery settings - and the SMTP credentials live next to it. So an AI can build
a form but cannot make it deliver. We need a SAFE way to bind a new form to a
transport the operator already trusts.
:::

## The wall (and why)

`lazysite/forms/*.conf` defines the handler: `type: smtp|file|webhook` plus its
settings. The destination (`to:`) and the SMTP credentials (`smtp.conf`) are the
exfiltration surface - an AI that could set `to:` could redirect every form
submission. So writing handler config from the connector is blocked on purpose.

## Safe options

1. **Bind-to-existing (recommended).** The operator configures handlers once;
   the connector only *references* one. New tools:
   - `list_form_handlers` - names + types of the configured handlers (no secrets,
     no `to:`/creds in the response).
   - `bind_form(form, handler)` - writes `lazysite/forms/<form>.conf` as a pure
     reference to an existing, operator-vetted handler. The AI never sets a
     destination or a credential; it picks from what already exists.
   A narrow, audited carve-out in the deny-list allows ONLY this reference write
   (validated to contain no `to:`/secret keys).
2. **Operator-approval queue.** The AI proposes `form -> handler`; it lands as a
   pending binding the operator confirms with one click in the manager. Nothing
   delivers until approved.
3. **Site default delivery.** A site-level default handler; `bind_form` only sets
   `type` and the form inherits the operator-owned destination. The AI never
   names a recipient.

Recommendation: option 1, with the hard invariant that **destination + credentials
are never connector-settable** - the connector chooses among existing handlers,
it does not define delivery. Option 2 layers on top for sites that want a human
in the loop.

## Notes

- `list_form_handlers` is independently useful (the AI currently can't even see
  which handlers exist - it had to infer from byte sizes).
- Keep `smtp.conf` and any `to:`/secret strictly operator-only and out of every
  connector response (as today).
- Audit every bind (material: it changes where submissions go).

## Status

**Done (2026-06-25)** - option 1 (bind-to-existing). `list_form_handlers` +
`bind_form(form, handler)` MCP tools: the connector references an existing
operator-vetted handler by id and never sets a destination or credential. The
operator-approval queue (option 2) remains a possible follow-on. Complements the
page-aware API ([[SM087]]).

## Status (reconciled)

**SHIPPED (bind_form + list_form_handlers in the MCP; enhanced in v0.4.38).**
