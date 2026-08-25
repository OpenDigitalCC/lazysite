---
title: "SM590: table delivery is handler-only, and nothing says so"
subtitle: "bind_form's inline target offers webhook, api and file. SM569 added a table handler type the inline route cannot reach - which is defensible, and undocumented, so a reader cannot tell design from oversight."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.33: bind_form's description and starter/docs/forms.md both state that `db` and `table` delivery is handler-only and why - the inline route exists for a destination the operator has not pre-defined, and a form writing rows into a declared table is exactly what they should vet. VERIFIED BEFORE DOCUMENTING, not assumed: _inline_target_block already refuses anything outside webhook|api|file, so the sentence describes what the code does. t/unit/mcp/17 now pins both spellings, asserting the refusal NAMES the allowed types - a weaker assertion would still pass with db allowed, because a db target carries no url and would be refused for the wrong reason. RAISED BY THE SITE AGENT 2026-08-25 on 0.10.32 with manage_forms + manage_data, unable to exercise SM569 and careful to say that is not a failure: edge has one handler (local-storage, type file), handler definitions live in lazysite/forms/handlers.conf which is operator/cookie territory on every surface, and bind_form's inline target schema advertises {type: webhook|api, url} or {type: file, path} with additionalProperties false - no table type, no table name. They set out both readings and could not distinguish them: table delivery is deliberately handler-only, or the tool schema was not updated alongside the feature. IT IS THE FIRST, and the reasoning is the same one the tool's own description gives for credentials: the inline route exists so a partner can deliver 'somewhere the operator has not pre-defined', and a form writing rows into a declared data table is precisely what should be operator-vetted - an inline table target would let a partner name any declared table as a destination without the operator wiring it. WHAT IS MISSING IS THE SENTENCE. SHIPPED as documentation in 0.10.33: bind_form's description states that table delivery is handler-only and why; the forms docs say the same where an author reads them. ALSO RECORDED, from the agent: SM563's four-surface lint compares CAPABILITIES across the tables, not schema CONTENT - a tool whose schema omits a delivery type the engine supports is well-formed and correctly gated, and the lint would not see it. Whether that reach is worth extending is a separate decision, noted on SM563."
---

# Why handler-only is right

| Inline target | Handler |
|---|---|
| the partner names the destination | the operator vets it |
| a URL or a directory | a declared table, with a column mapping |

A table destination carries the same authority question as a credential:
it is the operator's to grant, not the partner's to choose.

# Proving test

`bind_form`'s description names table delivery as handler-only;
`t/lint/80`-style doc coverage asserts the forms documentation says so
where an author would look.
