---
title: "SM227 - The submission store reads as write-only"
subtitle: "form_list returns row counts and never content, by design. Combined with an ungranted read_submissions, a partner concludes submissions cannot be read at all and builds a replacement store."
brand: plain
status: candidate
status-note: "Raised 2026-08-06 from the Golden Link partner review, where forms were rejected as an intake mechanism on this basis and a private JSON store was specified instead. Implementation targeted for the next release. Compounds with SM226; both should ship together."
---

# SM227 - the submission store reads as write-only

## Why

Two correct design decisions combine into a wrong conclusion.

`form_list` returns per form: name, handler types, whether a store exists, and
`rows` - the submission **count** only, never content. That is deliberate
least-privilege design and it should stay.

`read_form_submissions` returns the rows themselves, behind a `read_submissions`
capability that is a genuine least-privilege split: it permits reading
submissions without permitting any edit to forms or handlers. Also good design.

A partner holding `manage_forms` but not `read_submissions` sees a tool that
reports counts, no tool that reports content, and a `false` against
`read_submissions` in the capability map. In August 2026 one reasoned:

> `:::form` blocks are field-validated line by line, `form_list` returns row
> counts rather than content, submissions are append-only, and
> `read_submissions` is off on the agency account. It is a lead collector,
> correctly designed as one.

and specified a separate private JSON store with ETags, conflict handling, quota
and its own token scope - several days of work to replace a feature that was
present, working and one grant away.

Their substantive point deserves recording, because it is partly right: forms
*are* field-validated per field and append-only, which makes them a poor fit for
a large mutable document. But "cannot read what was submitted" was never true,
and that was the belief the design turned on.

## What is true today

- `form_list` (`lazysite-mcp.pl:643`) - cap `read_submissions`, returns counts.
  Its description already names `read_form_submissions` as the companion.
- `read_form_submissions` (`lazysite-mcp.pl:649`) - cap `read_submissions`,
  returns `{ columns, rows, total, shown }`, most recent 500, stable `_id` per
  row.
- Both are filtered out of the advertised tool list entirely when the capability
  is absent (`_tool_callable`), so a partner without the grant never sees the
  companion description that would have corrected them.

That last point is the mechanism. The cross-reference exists; it is invisible to
exactly the partner who needs it.

## What to build

### 1. Name the gated capability where the gap is felt

When a capability filters tools out of the advertised list, the partner should
still be able to learn that the tools exist and what grant would unlock them.
`describe_capabilities` already returns `capabilities` with an `unlocks` block
per capability, which is the right place - SM226 makes the `holds` block
self-describing, and this request ensures `unlocks` for `read_submissions`
names `read_form_submissions` explicitly enough that a reader connects them.

### 2. Say what `rows` is in the response, not only in the description

`form_list` should return the count under a name that cannot be mistaken for
data, and carry a short note in the payload pointing at the companion tool and
its capability. A partner reading a response rarely re-reads the tool
description that produced it.

### 3. Document the intake pattern

`/docs/forms` should state plainly that a form is a supported intake mechanism
for structured material, that submissions are readable through
`read_form_submissions` with the least-privilege grant, and that fields support
long text and file upload (see SM229 for the notification half of the same
story). The reviewer also believed no file upload existed; it does, with
configurable per-file and per-submission limits.

## Verification

- A partner without `read_submissions` can discover, from
  `describe_capabilities` alone, that submission reading exists and which grant
  provides it.
- `form_list`'s response is self-describing about what it does and does not
  contain.
- `/docs/forms` covers reading submissions and file upload.

## Not in scope

- Changing the least-privilege split. `form_list` should keep returning counts
  and `read_submissions` should remain separate from `manage_forms`; both are
  right.
- Making forms suitable for large mutable documents. That criticism is fair and
  is a different request if anyone wants it.
