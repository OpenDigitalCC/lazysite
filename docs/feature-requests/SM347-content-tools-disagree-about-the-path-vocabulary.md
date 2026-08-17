---
title: "SM347 - Two content tools reject a path the other four accept"
subtitle: "`create_page` takes a slug and reports the `.md` path it wrote. Reading that page back at the path you just used returns `File not found` with `retryable:false` - while the page serves 200 over HTTP. Four of six content tools resolve the extension; two do not."
brand: plain
status: filed
---

# SM347 - the create-then-read sequence fails

## What was measured

edge 0.10.12, MCP surface, one page created and then addressed by every
content tool that takes a `path`, in both forms.

```datatable
columns: Tool | `/zz-surv/probe` | `/zz-surv/probe.md`
widths: 5.4cm | 4.2cm | X
bold: 1
tone: medium
---
`page_status` | ok | ok
`preview_page` | ok | ok
`list_versions` | ok | ok
`invalidate_cache` | ok | ok
`read_page` | **not-found** | ok
`validate_page` | **not-found** | ok
```

The page was created with `create_page {"slug":"zz-surv/probe"}`, which
returned `{"created":1,"path":"/zz-surv/probe.md","ok":1}`, and it served
200 at `/zz-surv/probe` throughout.

## Why this is worse than an inconsistency

**The natural sequence is the one that fails.** An agent creates a page
with a slug, then reads it back to confirm what it wrote. That is the
first thing anything does after a write, and it is the path the tool
itself just reported.

**The refusal is confident and tells you to stop.**

```
{"error":"File not found","kind":"not-found","ok":0,"retryable":false,
 "hint":"Do not retry - this will not succeed unless the request changes
         or the operator grants access."}
```

Both halves of that hint are misleading here. The operator does not need
to grant anything, and "the request changes" is true only in a sense the
message never reveals. A caller reading this concludes the page does not
exist - and the runbook for this instance already records a near-miss of
exactly that shape: *"a wrong key looks exactly like an empty result...
produced 'zero versions' and a nearly-filed defect report."*

**It is invisible to a caller who does not test both forms.** Four tools
work, so nothing signals that two are different. The `path` parameter has
the same name and the same description shape across all six.

## The fix

Resolve the extension in `read_page` and `validate_page`, as the other
four already do. That is the smaller change and the one that removes the
question rather than documenting it.

If there is a reason those two must have the literal file - and there may
be, since `validate_page` validates a file's content and `read_page`
returns it - then the refusal must name the cause:

```
no such file; the page at this path is stored as <path>.md - did you mean that?
```

A caller can act on that. It cannot act on `File not found`.

## Worth settling at the same time

`create_page` takes `slug` while every other tool takes `path`, and the
slug is extensionless while the returned `path` is not. That is a second
vocabulary boundary in the same workflow. Either the create tool should
accept `path` as an alias, or its `slug` description should say plainly
that the created file gains `.md` and that some tools want it.

## Verification

- `read_page` and `validate_page` accept `/x/y` for a page stored at
  `/x/y.md`, matching `page_status`.
- A path that genuinely does not exist still returns `not-found`.
- If the extension-resolving fix is declined, the refusal for a
  resolvable path names the `.md` file and does not say `retryable:false`
  with a grant hint.
- A fixture drives create-then-read through the slug path returned by
  `create_page` and asserts it succeeds.

## Related

[[SM314]] (a tool description that did not match behaviour, same class of
agent-facing defect), and
`inbox/four-surface-validation-0.10.12-2026-08-17.md`, the pass this came
from.
