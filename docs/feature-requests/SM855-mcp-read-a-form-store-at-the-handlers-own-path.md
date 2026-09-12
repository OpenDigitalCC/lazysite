---
id: SM855
title: "SM855: MCP read a form's submissions from the default directory whatever store the form was bound to, and called an empty answer a success"
subtitle: "read_form_submissions built lazysite/forms/submissions/<form>.jsonl from the form name. A form bound to a file handler with its own `path:` was therefore read from a file that was not its store - and answered ok: true, total: 0, naming that file, while the control API's form-list reported the row that was in the real one."
brand: plain
standard-margins: true
status: shipped
raised: 2026-09-12
raised-by: site agent (1313E-01 step 6)
area: mcp
---

# What was found

The 1313E pass bound a form to a file handler keeping its store at
`1313e-store`, submitted anonymously, and then asked each surface for the
submission:

| Asked | Answered |
| --- | --- |
| `form-list` (control API) | `has_store: true`, `row_count: 1` |
| `form-submissions&file=1313e-store/...` | the row |
| WebDAV GET of the store | the row |
| MCP `read_form_submissions{form}` | **`ok: true`, `total: 0`**, naming `lazysite/forms/submissions/1313e-file-form.jsonl` |

Three surfaces knew where the store was. The fourth reported success about a
file it had constructed, which did not exist.

# Why it matters more than a missing feature

This is the shape the site agent filed as SM768 and met again here: **a reader
that turns "I am looking in the wrong place" into "there is nothing here."** An
agent asked to check whether a form has been submitted gets a confident no, and
the submissions are sitting in the store the same engine wrote them to.

# The cause

The tool took the form name and built the path:

```perl
return action_form_submissions("lazysite/forms/submissions/$form.jsonl");
```

A form's store is not a default: it is the path of the file handler the form is
bound to, which may name its own. The control API's `form-list` worked that out
inline - read the form's conf, find its handlers, take the first file handler's
`path:` - and MCP had no equivalent. Two readers, one of which did not know the
rule.

# The fix

One resolver, in `Lazysite::Handlers`, where the handler contract lives:

- `form_store_dir($form)` - the configured directory, relative, as
  `handlers.conf` writes it. The submissions readers confine a path against the
  configured stores (SM268 H1), so they need the relative form.
- `form_store_file($form)` - that directory resolved, plus `<form>.jsonl`, for
  readers that want the absolute path.

MCP asks `form_store_dir`. `form-list`'s inline copy is gone and calls
`form_store_file`. The description of the MCP tool now says what it reads.

# Held by

`t/unit/mcp/27-a-form-store-at-a-handlers-own-path-is-read.t` - one form bound to
a handler with its own `path:`, one on the default, a row in each. It asserts the
moved store's row IS returned, that the answer does not name a file that is not
the store, that the default store still reads (the control), and that the
resolver and `form-list` agree about both. It fails against the shipped MCP.

# Not changed

The tool still takes a form NAME and not a file path. Naming a file is the
control API's shape (`form-submissions&file=...`) and that asymmetry is
deliberate: the form name is the thing an agent knows, and resolving it is the
engine's job - which is what this fixes.

# Related

[[SM768]] (the same shape: a wrong-place read reported as an empty result),
[[SM851]] (the carve-out for the same stores), [[SM842]] (the handler contract
this resolver belongs to), [[SM227]] (counts versus content).
